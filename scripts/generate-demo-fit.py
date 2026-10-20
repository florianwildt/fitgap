"""Development-only generation/validation using the official garmin-fit-sdk 21.218.0.

Follows https://developer.garmin.com/fit/articles/cookbook/encoding_activity_files.html
No downloaded activity data, GPS positions, user profiles or provider identifiers.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
from garmin_fit_sdk import Encoder, Decoder, Stream, Profile, FIT_EPOCH_S, __version__

ROOT = Path(__file__).resolve().parents[1] / 'Sources/FITgapCore/Resources/Demo'
SAMPLES = [
    ('recovery', '2026-06-15T07:00:00+00:00', 1800, 10800, 30, 120),
    ('endurance', '2026-06-13T09:30:00+00:00', 3600, 28800, 120, 145),
    ('tempo', '2026-06-10T17:15:00+00:00', 2400, 21600, 80, 155),
]


def generate(sample):
    name, iso, duration, distance, ascent, hr = sample
    start = int(datetime.fromisoformat(iso).timestamp()) - FIT_EPOCH_S
    end = start + duration
    encoder = Encoder()

    def write(kind, **fields):
        encoder.write_mesg({'mesg_num': Profile['mesg_num'][kind.upper()], **fields})

    write('file_id', type='activity', manufacturer='development', product=0,
          serial_number=1, time_created=start)
    write('device_info', timestamp=start, device_index='creator', manufacturer='development',
          product=0, serial_number=1, product_name='FITgap Demo', software_version=0.1)
    write('event', timestamp=start, event='timer', event_type='start', event_group=0)
    speed = distance / duration
    # A sample each 30 seconds, with a synthetic steady climb; no geographical coordinates.
    for second in range(0, duration + 1, 30):
        write('record', timestamp=start + second, distance=distance * second / duration,
              enhanced_speed=speed, enhanced_altitude=100 + ascent * second / duration,
              heart_rate=hr, cadence=85, power=160 if name == 'recovery' else 210)
    write('event', timestamp=end, event='timer', event_type='stop_all', event_group=0)
    summary = dict(timestamp=end, start_time=start, total_elapsed_time=duration,
                   total_timer_time=duration, total_distance=distance, total_ascent=ascent,
                   total_descent=0, enhanced_avg_speed=speed, enhanced_max_speed=speed,
                   avg_heart_rate=hr, max_heart_rate=hr, sport='cycling', sub_sport='indoor_cycling')
    write('lap', message_index=0, event='lap', event_type='stop', lap_trigger='session_end', **summary)
    write('session', message_index=0, event='session', event_type='stop',
          first_lap_index=0, num_laps=1, **summary)
    write('activity', timestamp=end, total_timer_time=duration, num_sessions=1,
          type='manual', event='activity', event_type='stop')
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / f'FITgap-Demo-{name}.fit').write_bytes(encoder.close())


def validate(sample):
    name, iso, duration, distance, ascent, hr = sample
    path = ROOT / f'FITgap-Demo-{name}.fit'
    decoder = Decoder(Stream.from_file(str(path)))
    assert decoder.is_fit() and decoder.check_integrity(), f'CRC/header failed: {path}'
    messages, errors = Decoder(Stream.from_file(str(path))).read()
    assert not errors, errors
    for kind in ['file_id', 'device_info', 'event', 'record', 'lap', 'session', 'activity']:
        assert messages[f'{kind}_mesgs'], kind
    session = messages['session_mesgs'][0]
    lap = messages['lap_mesgs'][0]
    records = messages['record_mesgs']
    assert session['sport'] == 'cycling' and session['sub_sport'] == 'indoor_cycling'
    for summary in [session, lap]:
        assert summary['start_time'] == datetime.fromisoformat(iso)
        assert summary['total_timer_time'] == summary['total_elapsed_time'] == duration
        assert summary['total_distance'] == distance and summary['total_ascent'] == ascent
        assert abs(summary['enhanced_avg_speed'] - distance / duration) < 0.001
    assert records[-1]['timestamp'] == session['timestamp']
    assert records[-1]['distance'] == distance
    assert records[-1]['enhanced_altitude'] - records[0]['enhanced_altitude'] == ascent
    assert messages['activity_mesgs'][0]['total_timer_time'] == duration
    assert all('position_lat' not in record and 'position_long' not in record for record in records)
    print(f'{path.name}: SDK {__version__}, CRC/decode OK, {len(records)} records, '
          f'{distance} m / {duration} s / {ascent} m, {path.stat().st_size} bytes, '
          f'SHA256 {hashlib.sha256(path.read_bytes()).hexdigest()}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    for sample in SAMPLES:
        if not args.validate_only:
            generate(sample)
        validate(sample)
