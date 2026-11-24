"""Test the embedded beacon's routing and passive-cache parsers without a phone."""
import subprocess
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name('default.nix').read_text()


def function(name):
    start = SOURCE.index('  ' + name + '() {')
    end = SOURCE.index('\n  }', start) + len('\n  }')
    return SOURCE[start:end].replace("''${", "${")


class Parsers(unittest.TestCase):
    def candidates(self, rules):
        script = 'ip() { cat <<\'RULES\'\n' + rules + '\nRULES\n}\n'
        script += function('list_candidates') + '\nlist_candidates\n'
        return subprocess.check_output(['bash', '-c', script], text=True).splitlines()

    def test_android16_tailscale_and_android17_vpn(self):
        rules = '''5210: from all fwmark 0x80000/0xff0000 lookup main
11000: from all iif lo oif dummy0 uidrange 0-0 lookup dummy0
11000: from all iif lo oif wlan0 uidrange 0-0 lookup wlan0
11000: from all iif lo oif rmnet_data2 uidrange 0-0 lookup rmnet_data2
16000: from all fwmark 0x101a9/0x1ffff iif lo lookup wlan0
16000: from all fwmark 0xd019a/0xdffff iif lo lookup rmnet_data2'''
        self.assertEqual(self.candidates(rules),
                         ['default 0x0', 'wlan0 0x101a9', 'rmnet_data2 0xd019a'])
        self.assertEqual(self.candidates(rules + '\n13000: from all fwmark 0/0x20000 iif lo lookup tun0'),
                         ['wlan0 0x101a9', 'rmnet_data2 0xd019a', 'default 0x0'])

    def test_stale_cleanup_cannot_remove_replacement_pid(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            script = 'PIDFILE=' + directory + '/beacon.pid\n'
            script += 'stop_tunnel() { echo stopped; }\n'
            script += function('cleanup') + '\n'
            script += 'echo replacement > "$PIDFILE"; cleanup; cat "$PIDFILE"\n'
            script += 'echo $$ > "$PIDFILE"; cleanup; test ! -e "$PIDFILE"\n'
            result = subprocess.check_output(['bash', '-c', script], text=True)
            self.assertEqual(result.splitlines(), ['replacement', 'stopped'])

    def test_no_rules_has_normal_route(self):
        self.assertEqual(self.candidates(''), ['default 0x0'])

    def test_changed_rule_priorities(self):
        self.assertEqual(self.candidates('''11500: from all iif lo oif wlan0 uidrange 0-0 lookup 101
16500: from all fwmark 0x10065/0x1ffff iif lo lookup 101'''),
                         ['default 0x0', 'wlan0 0x10065'])

    def test_prefers_unmasked_precise_location_over_coloros_masked_summary(self):
        parser = function('cached_location').replace(
            'timeout 4 /system/bin/dumpsys location', 'cat')
        data = ''' last location=Location[network 31.23****,121.53**** hAcc=24.0 et=+1d1h2m3s222ms]
 Historical Locations:
   Location[network 31.225812,121.529274 hAcc=24.0 et=+1d1h2m3s222ms]
   Location[gps 31.100000,121.400000 hAcc=3 et=+1d0h1s]
'''
        script = 'boottime_sec() { echo 90200; }\n' + parser + '\ncached_location\n'
        result = subprocess.check_output(['bash', '-c', script], input=data, text=True)
        self.assertEqual(result.strip(), '31.225812 121.529274 network 24.0 +1d1h2m3s222ms 77')


if __name__ == '__main__':
    unittest.main()
