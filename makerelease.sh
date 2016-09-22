#!/bin/bash
if [ ! -d "release" ]; then
  mkdir release
else
  rm -rf release/*
fi
./clean.sh
./compile.sh
cp godaemontask release
cp release-files/* release

currentdate=$(date '+%Y-%m-%d')
systemtype=$(fpc -iTO -iTP)
systemtype="${systemtype/ /-}"
name="godaemon.$currentdate.$systemtype.tar.gz"
tar -czf $name release
mv $name release

echo -----------------------------------------
echo Release built: release/$name
echo -----------------------------------------
