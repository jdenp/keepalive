@echo off
rem dummy server for the test suite: opens port 18099, accepts, idles
echo dummy server on --port 18099
python "%~dp0dummy_server.py"
