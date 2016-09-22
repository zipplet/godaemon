#!/bin/sh
LCORE="../libs/lcore"
COMMONOPTS="-Fu${LCORE} -Fi${LCORE} -Sd -XX"
FPC="fpc"
./clean
$FPC $COMMONOPTS godaemontask.dpr
