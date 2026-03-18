FROM python:3.14-slim

WORKDIR /app

RUN pip install --no-cache-dir --break-system-packages paho-mqtt requests meshtastic pytest

COPY src/bot.py src/test_bot.py .

RUN python -m pytest test_bot.py -v

CMD ["python", "bot.py"]
