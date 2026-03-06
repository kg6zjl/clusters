meshtastic --host 192.168.1.139 --set region US
meshtastic --host 192.168.1.139 --set preset MediumFast


meshtastic --host 192.168.1.139 --ch-add 4
meshtastic --host 192.168.1.139 --ch-index 4 --ch-set name eastbay
meshtastic --host 192.168.1.139 --ch-index 4 --ch-enable
meshtastic --host 192.168.1.139 --reboot