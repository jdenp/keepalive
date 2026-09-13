import socket, time, threading

PORT = 18099

def accept_loop(s):
    while True:
        try:
            c, _ = s.accept()
            c.close()
        except Exception:
            break

s = socket.socket()
s.bind(('127.0.0.1', PORT))
s.listen(8)
threading.Thread(target=accept_loop, args=(s,), daemon=True).start()
time.sleep(300)
