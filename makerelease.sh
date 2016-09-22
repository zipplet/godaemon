#!/bin/sh
if [ ! -d "release" ]; then
  mkdir release
else
  rm -rf release/*
fi
./clean.sh
./compile.sh
cp godaemontask release
cp release-files/* release
echo -----------------------------------------
echo Release built and placed in "./release/".
echo -----------------------------------------
