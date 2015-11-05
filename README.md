godaemon
========

Daemoniser/task manager for daemons.

Run a program (e.g. a normal program written in Go, Python, Ruby...) as a daemon, with the following extra features:

* A true daemon (detaches from the session group and is immune to session signals)
* Automatically restart the program if it stops
* Capture the output of the program to a log file (compatible with log rotate)
* Log program restarts / failures
* Send an email if the program crashes and is restarted
* Include last few lines of log output in the email to help diagnose the problem
* Safety throttle (don't restart too many times or too quickly)
* Nagios plugin mode - report status of the daemon to nagios/icinga via NRPE
* Run task as a different user or group

Why:
* Go programs cannot become daemons (fork/threads/goroutines issue)
* Most other daemonisers don't handle auto restart nicely (safety throttle)
* Most other daemonisers can't send an email on task restart
* Lightweight and simple
* Plugs into nagios/icinga easily

OS:
* Currently only Linux.

Builds:
* Coming soon.

License:
* MIT license - see LICENSE file.