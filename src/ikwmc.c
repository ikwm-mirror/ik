#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static const char *usage =
    "Usage: ikwmctl <command> [args]\n"
    "\n"
    "Commands:\n"
    "  focus next|prev|left|right|up|down\n"
    "  kill\n"
    "  fullscreen\n"
    "  floating\n"
    "  tiling\n"
    "  rotate\n"
    "  split h|v|horizontal|vertical\n"
    "  ratio <0.1-0.9>\n"
    "  gap inner|outer <n>\n"
    "  border width <n>\n"
    "  border outer_width <n>\n"
    "  border color active|normal|outer_active|outer_normal <xxxxxxxx>\n"
    "  wallpaper color <xxxxxxxx>\n"
    "  workspace <n>\n"
    "  workspace goto <n>\n"
    "  workspace move <n>\n"
    "  spawn <command...>\n"
    "  query focused\n"
    "  quit\n";

int main(int argc, char **argv) {
  if (argc < 2) {
    fputs(usage, stderr);
    return 1;
  }

  /* build command string (argv[1..]) */
  size_t total = 0;
  for (int i = 1; i < argc; i++)
    total += strlen(argv[i]) + 1; // space or newline

  char *cmd = malloc(total + 1);
  if (!cmd) {
    perror("malloc");
    return 1;
  }

  cmd[0] = '\0';
  for (int i = 1; i < argc; i++) {
    if (i > 1)
      strcat(cmd, " ");
    strcat(cmd, argv[i]);
  }
  strcat(cmd, "\n");

  /* socket path */
  char path_buf[256];
  const char *sock_path = getenv("IKWM_SOCKET");
  if (!sock_path) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime)
      runtime = "/tmp";
    snprintf(path_buf, sizeof(path_buf), "%s/ikwm.sock", runtime);
    sock_path = path_buf;
  }

  int sock = socket(AF_UNIX, SOCK_STREAM, 0);
  if (sock < 0) {
    perror("socket");
    free(cmd);
    return 1;
  }

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

  if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    fprintf(stderr, "ikwmctl: cannot connect to %s: ", sock_path);
    perror(NULL);
    close(sock);
    free(cmd);
    return 1;
  }

  size_t len = strlen(cmd);
  size_t sent = 0;
  while (sent < len) {
    ssize_t n = write(sock, cmd + sent, len - sent);
    if (n < 0) {
      perror("write");
      close(sock);
      free(cmd);
      return 1;
    }
    sent += (size_t)n;
  }
  free(cmd);

  int is_query = strncmp(argv[1], "query", 5) == 0;
  if (is_query) {
    shutdown(sock, SHUT_WR);
    char buf[4096];
    ssize_t n;
    while ((n = read(sock, buf, sizeof(buf))) > 0)
      fwrite(buf, 1, (size_t)n, stdout);
  }

  close(sock);
  return 0;
}
