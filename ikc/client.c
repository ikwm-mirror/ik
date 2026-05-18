#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static const char *usage =
    "Usage: ikc <domain> <command> [args]\n"
    "\n"
    "Node:\n"
    "  node focus next|prev|left|right|up|down\n"
    "  node swap  next|prev|left|right|up|down\n"
    "  node kill\n"
    "  node close\n"
    "  node fullscreen\n"
    "  node floating\n"
    "  node tiling\n"
    "  node rotate\n"
    "  node split h|v|horizontal|vertical\n"
    "  node ratio <0.1-0.9>\n"
    "\n"
    "Desktop:\n"
    "  desktop focus <n>\n"
    "  desktop send  <n>\n"
    "  desktop count <n>\n"
    "\n"
    "Config:\n"
    "  config get <key>\n"
    "  config set <key> <value>\n"
    "  Keys: border_width border_outer_width border_color_active\n"
    "        border_color_normal border_outer_color_active "
    "border_outer_color_normal\n"
    "        gap_inner gap_outer wallpaper_color decor decor_default\n"
    "        workspace_count motion_throttle_hz\n"
    "\n"
    "Bind:\n"
    "  bind add [mode] <mods+key> <command...>\n"
    "  bind list [mode]\n"
    "\n"
    "Mode:\n"
    "  mode enter <name>\n"
    "  mode leave\n"
    "  mode define <name>\n"
    "  mode remove <name>\n"
    "\n"
    "WM:\n"
    "  wm spawn <command...>\n"
    "  wm quit\n"
    "  wm reload\n"
    "\n"
    "Query (prints JSON):\n"
    "  query focused\n"
    "  query workspaces\n"
    "  query clients\n"
    "  query clients all\n"
    "  query mode\n"
    "  query binds [mode]\n"
    "  query config\n"
    "  query status\n"
    "\n"
    "Follow (persistent, prints JSON on each change):\n"
    "  follow [workspace|focus|client|mode|config|all...]\n";

static int is_reader(int argc, char **argv) {
  if (argc < 2)
    return 0;
  if (strcmp(argv[1], "query") == 0)
    return 1;
  if (strcmp(argv[1], "follow") == 0)
    return 1;
  if (strcmp(argv[1], "bind") == 0 && argc >= 3 && strcmp(argv[2], "list") == 0)
    return 1;
  if (strcmp(argv[1], "config") == 0 && argc >= 3 &&
      strcmp(argv[2], "get") == 0)
    return 1;
  return 0;
}

static int is_follow(int argc, char **argv) {
  return argc >= 2 && strcmp(argv[1], "follow") == 0;
}

static const char *socket_path(char *buf, size_t bufsz) {
  const char *s = getenv("IKWM_SOCKET");
  if (s)
    return s;
  const char *runtime = getenv("XDG_RUNTIME_DIR");
  snprintf(buf, bufsz, "%s/ikwm.sock", runtime ? runtime : "/tmp");
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fputs(usage, stderr);
    return 1;
  }

  size_t total = 0;
  for (int i = 1; i < argc; i++)
    total += strlen(argv[i]) + 1;
  char *cmd = malloc(total + 2);
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

  char path_buf[256];
  const char *sock_path = socket_path(path_buf, sizeof(path_buf));

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
    fprintf(stderr, "ikc: cannot connect to %s: ", sock_path);
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
      break;
    }
    sent += (size_t)n;
  }
  free(cmd);

  if (!is_reader(argc, argv)) {
    close(sock);
    return 0;
  }

  if (!is_follow(argc, argv))
    shutdown(sock, SHUT_WR);

  char buf[4096];
  ssize_t n;
  while ((n = read(sock, buf, sizeof(buf))) > 0)
    fwrite(buf, 1, (size_t)n, stdout);

  fflush(stdout);
  close(sock);
  return 0;
}
