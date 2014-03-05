install:
	install -m 755 -o root -g root -d /usr/local/share/vzbkp
	install -m 755 -o root -g root -t /usr/local/share/vzbkp functions.sh
	install -m 755 -o root -g root -t /usr/local/bin vzbkp-dump
	install -m 755 -o root -g root -t /usr/local/bin vzbkp-restore
	test -f /usr/local/etc/vzbkp.conf || install -m 644 -o root -g root -t /usr/local/etc vzbkp.conf
	test -f /etc/cron.d/vzbkp || install -m 644 -o root -g root -T vzbkp.cron /etc/cron.d/vzbkp

