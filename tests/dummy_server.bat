@echo off
rem dummy llama server for the test suite: opens port 18099, accepts, idles
echo dummy llama-server on --port 18099
python C:\Repos\keepalive\tests\dummy_server.py
