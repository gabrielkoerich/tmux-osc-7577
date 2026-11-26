/*
 * One process reads the output of every tmux pane. pipe-pane runs `osc7577 pass`, which hands its stdin to the
 * hub over a Unix socket and exits. tmux keeps writing to that socket, since it tracks only the fd and never the
 * child, so a pane costs a few bytes in the hub and no process of its own
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAXPANES 4096
#define MAXBODY 4096
#define MAXJOBS 16
#define PERSEC 5
#define MAXFDS 64

static const char opener[] = "\033]7577;";

struct pane {
	int fd;
	char id[16];
	int state;		/* bytes of the opener matched, 7 inside a body, 8 after an ESC in it */
	size_t len;
	char *body;		/* MAXBODY + 1 bytes, only while a sequence is being read */
	time_t second;
	int sent;
	pid_t job;		/* the accept checking this pane's last report */
	char *pending;		/* the newest report that came while it ran */
	size_t plen;
};

static struct pollfd fds[MAXPANES + 1];
static struct pane panes[MAXPANES + 1];
static int npanes;
static int jobs;
static long fd_room;
static const char *accept_cmd;

static int
fail(const char *why)
{
	fprintf(stderr, "osc7577: %s: %s\n", why, strerror(errno));
	return 1;
}

static int
digits(const char *s)
{
	if (*s == '\0' || strlen(s) > 10)
		return 0;
	for (; *s != '\0'; s++)
		if (*s < '0' || *s > '9')
			return 0;
	return 1;
}

static int
nonblock(int fd)
{
	return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

/* Only a body the spec would not ignore anyway: a mac of 64 hex digits last and a time inside the window */
static int
worth_checking(const char *b, size_t n)
{
	const char *t;
	char *end;
	long long v;
	time_t now;
	size_t i;

	if (n < 70 || memcmp(b + n - 69, ":mac=", 5) != 0)
		return 0;
	for (i = n - 64; i < n; i++)
		if (!((b[i] >= '0' && b[i] <= '9') || (b[i] >= 'a' && b[i] <= 'f')))
			return 0;
	for (t = b; (t = strstr(t, "time=")) != NULL; t += 5) {
		if (t != b && t[-1] != ':')
			continue;
		v = strtoll(t + 5, &end, 10);
		if (end == t + 5 || *end != ':')
			return 0;
		now = time(NULL);
		return v >= (long long)now - 60 && v <= (long long)now + 60;
	}
	return 0;
}

/* Starts accept with the body on stdin and does not wait for it, so a slow check never holds up pane output */
static void
run(struct pane *p, const char *body, size_t len)
{
	char pane[18];
	int in[2];
	pid_t pid;

	if (jobs >= MAXJOBS || fd_room < 4 || pipe(in) == -1)
		return;
	snprintf(pane, sizeof pane, "%%%s", p->id);
	if ((pid = fork()) == -1) {
		close(in[0]);
		close(in[1]);
		return;
	}
	if (pid == 0) {
		signal(SIGPIPE, SIG_DFL);
		dup2(in[0], 0);
		close(in[0]);
		close(in[1]);
		execl(accept_cmd, accept_cmd, pane, (char *)NULL);
		_exit(127);
	}
	jobs++;
	p->job = pid;
	close(in[0]);
	/* A pipe holds more than MAXBODY, so this write never blocks */
	if (write(in[1], body, len) == -1)
		fail("write");
	close(in[1]);
}

/* One check at a time for each pane, so its reports keep their order, the newest waits for the running one */
static void
dispatch(struct pane *p)
{
	time_t now = time(NULL);

	if (now != p->second) {
		p->second = now;
		p->sent = 0;
	}
	if (++p->sent > PERSEC)
		return;
	if (p->job == 0) {
		run(p, p->body, p->len);
		return;
	}
	if (p->pending == NULL && (p->pending = malloc(MAXBODY)) == NULL)
		return;
	memcpy(p->pending, p->body, p->len);
	p->plen = p->len;
}

static void
reap(void)
{
	pid_t pid;
	int i;

	while (jobs > 0 && (pid = waitpid(-1, NULL, WNOHANG)) > 0) {
		jobs--;
		for (i = 1; i <= npanes; i++) {
			if (panes[i].job != pid)
				continue;
			panes[i].job = 0;
			if (panes[i].pending != NULL) {
				run(&panes[i], panes[i].pending, panes[i].plen);
				free(panes[i].pending);
				panes[i].pending = NULL;
			}
			break;
		}
	}
}

static void
end_body(struct pane *p)
{
	free(p->body);
	p->body = NULL;
}

static void
feed(struct pane *p, const unsigned char *buf, ssize_t n)
{
	ssize_t i;
	unsigned char c;

	for (i = 0; i < n; i++) {
		c = buf[i];
		if (p->state < 7) {
			if (c == (unsigned char)opener[p->state])
				p->state++;
			else
				p->state = c == 033 ? 1 : 0;
			if (p->state == 7) {
				if (p->body == NULL && (p->body = malloc(MAXBODY + 1)) == NULL)
					p->state = 0;
				p->len = 0;
			}
			continue;
		}
		if (p->state == 8) {
			p->body[p->len] = '\0';
			if (c == '\\' && worth_checking(p->body, p->len))
				dispatch(p);
			/* ESC inside an OSC starts a new escape, which may be the next report */
			p->state = c == 033 ? 1 : c == ']' ? 2 : 0;
		} else if (c == 007) {
			p->body[p->len] = '\0';
			if (worth_checking(p->body, p->len))
				dispatch(p);
			p->state = 0;
		} else if (c == 033)
			p->state = 8;
		else if (p->len == MAXBODY || c < 0x20 || c > 0x7e)
			p->state = 0;
		else
			p->body[p->len++] = c;
		if (p->state < 7)
			end_body(p);
	}
}

static uid_t
peer_uid(int s)
{
#ifdef SO_PEERCRED
	struct ucred cr;
	socklen_t len = sizeof cr;

	if (getsockopt(s, SOL_SOCKET, SO_PEERCRED, &cr, &len) == 0)
		return cr.uid;
#else
	uid_t uid;
	gid_t gid;

	if (getpeereid(s, &uid, &gid) == 0)
		return uid;
#endif
	return (uid_t)-1;
}

/* Keeps the first fd a message carries and closes every other, a peer may send several */
static int
first_fd(struct msghdr *m)
{
	struct cmsghdr *h;
	int fd = -1, got, k, n;

	for (h = CMSG_FIRSTHDR(m); h != NULL; h = CMSG_NXTHDR(m, h)) {
		if (h->cmsg_level != SOL_SOCKET || h->cmsg_type != SCM_RIGHTS || h->cmsg_len < CMSG_LEN(sizeof(int)))
			continue;
		n = (h->cmsg_len - CMSG_LEN(0)) / sizeof(int);
		for (k = 0; k < n; k++) {
			memcpy(&got, (char *)CMSG_DATA(h) + k * sizeof(int), sizeof got);
			if (fd == -1)
				fd = got;
			else
				close(got);
		}
	}
	return fd;
}

/* Takes one pane's fd from a pass client, which sends the pane number with it, waiting on it 100 ms at most */
static void
take_one(int s)
{
	union {
		struct cmsghdr h;
		char b[CMSG_SPACE(sizeof(int) * MAXFDS)];
	} u;
	struct pollfd w = { s, POLLIN, 0 };
	struct msghdr m;
	struct iovec iov;
	char name[16];
	int fd, flags = 0;

#ifdef MSG_CMSG_CLOEXEC
	flags = MSG_CMSG_CLOEXEC;
#endif
	memset(&m, 0, sizeof m);
	memset(name, 0, sizeof name);
	iov.iov_base = name;
	iov.iov_len = sizeof name - 1;
	m.msg_iov = &iov;
	m.msg_iovlen = 1;
	m.msg_control = u.b;
	m.msg_controllen = sizeof u.b;
	if (peer_uid(s) != geteuid() || poll(&w, 1, 100) != 1 || recvmsg(s, &m, flags) <= 0)
		return;
	fd = first_fd(&m);
	if (fd == -1)
		return;
	if ((m.msg_flags & MSG_CTRUNC) || !digits(name) || npanes == MAXPANES || fd_room < 8) {
		fprintf(stderr, "osc7577: dropped pane %s\n", name);
		close(fd);
		return;
	}
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	nonblock(fd);
	npanes++;
	fd_room--;
	memset(&panes[npanes], 0, sizeof panes[npanes]);
	panes[npanes].fd = fd;
	memcpy(panes[npanes].id, name, sizeof name);
	fds[npanes].fd = fd;
	fds[npanes].events = POLLIN;
}

static void
take(int listener)
{
	int s;

	while ((s = accept(listener, NULL, NULL)) != -1) {
		fcntl(s, F_SETFD, FD_CLOEXEC);
		take_one(s);
		close(s);
	}
}

static void
drop(int i)
{
	close(panes[i].fd);
	free(panes[i].body);
	free(panes[i].pending);
	panes[i] = panes[npanes];
	fds[i] = fds[npanes];
	npanes--;
	fd_room++;
}

/* Room for every pane up to the hard limit, a tmux started by launchd gets a soft limit of 256 */
static void
raise_limit(void)
{
	struct rlimit r;

	if (getrlimit(RLIMIT_NOFILE, &r) == 0) {
		if (r.rlim_cur < r.rlim_max) {
			r.rlim_cur = r.rlim_max > MAXPANES + 64 ? MAXPANES + 64 : r.rlim_max;
			setrlimit(RLIMIT_NOFILE, &r);
			getrlimit(RLIMIT_NOFILE, &r);
		}
		fd_room = (long)r.rlim_cur - 16;
	} else
		fd_room = 240;
}

static int
hub(const char *path, pid_t server)
{
	struct sockaddr_un sa;
	unsigned char buf[16384];
	char lockfile[sizeof sa.sun_path + 8], pidfile[sizeof sa.sun_path + 8];
	ssize_t r;
	FILE *f;
	int i, lock;

	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof sa.sun_path)
		return 2;
	strcpy(sa.sun_path, path);
	snprintf(lockfile, sizeof lockfile, "%s.lock", path);
	snprintf(pidfile, sizeof pidfile, "%s.pid", path);
	umask(077);

	/* The lock is held for the hub's life, so only one hub binds the socket and writes the pid */
	if ((lock = open(lockfile, O_RDWR | O_CREAT | O_CLOEXEC, 0600)) == -1)
		return fail("open");
	if (flock(lock, LOCK_EX | LOCK_NB) == -1)
		return 0;
	unlink(path);
	if ((fds[0].fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1)
		return fail("socket");
	if (bind(fds[0].fd, (struct sockaddr *)&sa, sizeof sa) == -1 || listen(fds[0].fd, 1024) == -1)
		return fail("bind");
	fcntl(fds[0].fd, F_SETFD, FD_CLOEXEC);
	nonblock(fds[0].fd);
	fds[0].events = POLLIN;
	if ((f = fopen(pidfile, "w")) != NULL) {
		fprintf(f, "%ld\n", (long)getpid());
		fclose(f);
	}
	signal(SIGPIPE, SIG_IGN);
	raise_limit();

	for (;;) {
		reap();
		if (kill(server, 0) == -1 && errno == ESRCH)
			break;
		if (poll(fds, npanes + 1, jobs > 0 ? 100 : 2000) == -1) {
			if (errno == EINTR)
				continue;
			return fail("poll");
		}
		if (fds[0].revents & POLLIN)
			take(fds[0].fd);
		for (i = 1; i <= npanes; i++) {
			if (fds[i].revents == 0)
				continue;
			r = read(fds[i].fd, buf, sizeof buf);
			if (r > 0)
				feed(&panes[i], buf, r);
			else if (r == 0 || (errno != EAGAIN && errno != EINTR)) {
				drop(i);
				i--;
			}
		}
	}
	unlink(path);
	unlink(pidfile);
	return 0;
}

/* Hands stdin, the pane's pipe from tmux, to the hub with the pane number, then exits */
static int
pass(const char *path, const char *pane)
{
	union {
		struct cmsghdr h;
		char b[CMSG_SPACE(sizeof(int))];
	} u;
	struct sockaddr_un sa;
	struct msghdr m;
	struct iovec iov;
	struct cmsghdr *h;
	int s, t, fd = 0;

	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	if (!digits(pane) || strlen(path) >= sizeof sa.sun_path)
		return 2;
	strcpy(sa.sun_path, path);
	for (t = 0;; t++) {
		if ((s = socket(AF_UNIX, SOCK_STREAM, 0)) == -1)
			return fail("socket");
		if (connect(s, (struct sockaddr *)&sa, sizeof sa) == 0)
			break;
		close(s);
		if (t == 200)
			return fail("connect");
		usleep(10000);
	}
	memset(&m, 0, sizeof m);
	memset(&u, 0, sizeof u);
	iov.iov_base = (void *)pane;
	iov.iov_len = strlen(pane);
	m.msg_iov = &iov;
	m.msg_iovlen = 1;
	m.msg_control = u.b;
	m.msg_controllen = sizeof u.b;
	h = CMSG_FIRSTHDR(&m);
	h->cmsg_level = SOL_SOCKET;
	h->cmsg_type = SCM_RIGHTS;
	h->cmsg_len = CMSG_LEN(sizeof fd);
	memcpy(CMSG_DATA(h), &fd, sizeof fd);
	if (sendmsg(s, &m, 0) == -1)
		return fail("sendmsg");
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 5 && strcmp(argv[1], "hub") == 0) {
		accept_cmd = argv[4];
		return hub(argv[2], (pid_t)atol(argv[3]));
	}
	if (argc == 4 && strcmp(argv[1], "pass") == 0)
		return pass(argv[2], argv[3]);
	fprintf(stderr, "usage: osc7577 hub <socket> <server pid> <accept> | osc7577 pass <socket> <pane>\n");
	return 2;
}
