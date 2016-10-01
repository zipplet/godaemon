godaemon
========

Daemoniser/task manager for anything.

Run any program or script (e.g. a program written in Go, Python, Ruby...) as a daemon, with the following extra features:

* A true daemon (detaches from the session group and is immune to session signals)
* Automatically restart the program if it stops/crashes
* Capture the output of the program to a log file (compatible with log rotate)
* Logs program restarts / failures
* Sends an email if the program crashes and is restarted
* Includes the last few lines of log output in the email to help diagnose the problem
* Configurable safety throttle (don't restart too many times or too quickly)
* Nagios plugin mode - reports the status of the daemon to nagios/icinga via NRPE
* Runs the task as a different user or group in a sandbox (chroot support coming soon)

Why:
* This project started because Go programs cannot become daemons (fork/threads/goroutines issue)
* Most other daemonisers don't handle auto restart nicely (safety throttle)
* Most other daemonisers can't send an email on task restart
* Lightweight and simple to use
* Plugs into nagios/icinga easily - godaemon itself can be called by NRPE so you do not need to write a plugin yourself
* Very lightweight memory and CPU footprint, and no system library dependencies
* Multiple copies of godaemon on the same host will consume very little memory, if you need to daemonise many tasks

OS:
* Linux is fully supported.
* Mac OS support almost works, but not quite - coming later.
* Windows support will be added later, but it will work differently (Windows Service)

Binaries (see releases):
* x86 and x64 Linux builds have been released that should run under any reasonably modern distro (statically linked binaries with no dependencies)
* Raspberry Pi builds have been released but have **not been tested on the Pi 3**, only on the Pi 1 and Pi 2.

Production stability:
* On Linux, godaemon has been in production use for quite some time.
* The ARM builds should be considered beta until fully tested (undergoing)

License:
* MIT license - see LICENSE file.
