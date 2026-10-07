// The lockdown writes the services helper runs as operations of its own child process
// (`LightTouchServices lockdown-tz …`, `LightTouchServices lockdown-mcinstall …`): lockdownd_set_value made
// in-process against 3.1.3's lockdownd corrupts the caller's heap, so each write gets a process to itself.
// argv[0] is the operation's name; the exit status is the operation's.
int ltm_lockdown_tz(int argc, char **argv);
int ltm_lockdown_mcinstall(int argc, char **argv);
