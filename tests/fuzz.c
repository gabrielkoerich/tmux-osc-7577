/* Feeds the hub's parser random streams built from pieces of reports, run under ASan and UBSan in CI */
#define main osc_main
#include "../src/osc7577.c"
#undef main

static char now_time[32];
static const char *pieces[] = {
	"\033", "]", "7577;", "\033]7577;", "\a", "\033\\", "time=", now_time, "x", ":mac=",
	"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "\x9c", "\n", "7", "\0", ":",
};
#define NPIECES (sizeof pieces / sizeof pieces[0])

int
main(int argc, char **argv)
{
	static unsigned char buf[20000];
	struct pane p;
	const char *t;
	size_t n, l;
	int it, chunk, k, r, m;

	accept_cmd = "/usr/bin/true";
	fd_room = 1000;
	srand(argc > 1 ? (unsigned)atoi(argv[1]) : 1);
	snprintf(now_time, sizeof now_time, "time=%ld:", (long)time(NULL));
	for (it = 0; it < (argc > 2 ? atoi(argv[2]) : 100000); it++) {
		memset(&p, 0, sizeof p);
		strcpy(p.id, "3");
		for (chunk = 0; chunk < 8; chunk++) {
			n = 0;
			for (k = rand() % 60; k > 0 && n < sizeof buf - 200; k--) {
				r = rand() % 20;
				if (r < 15) {
					t = pieces[rand() % NPIECES];
					l = t[0] == '\0' ? 1 : strlen(t);
					memcpy(buf + n, t, l);
					n += l;
				} else if (r < 18) {
					for (m = rand() % 1500; m > 0 && n < sizeof buf - 1; m--)
						buf[n++] = 'a' + rand() % 6;
				} else
					buf[n++] = rand();
			}
			feed(&p, buf, n);
			while (jobs > 0 && waitpid(-1, NULL, 0) > 0)
				jobs--;
			p.job = 0;
		}
		free(p.body);
		free(p.pending);
	}
	puts("ok");
	return 0;
}
