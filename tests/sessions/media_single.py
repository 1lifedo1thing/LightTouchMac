"""check-media-native.py --single: one prepared base of any board and build, booted through the app's session code
(tests/sessions/check-sessions.py --single --media), a tagged MP3 with a cover (and a photo) dropped through the app's
own import path (MediaSupport, PreparedMedia, MediaImport: AFC staging, the guest agent running itmedia/itphoto), then
judged on what the device keeps, read back over AFC: the song's title, artist and album in the device's library, its
cover's pixels in the device's ArtworkCache, the photo in DCIM; and Music opened on it (taps per board, screenshots of
the song list and the song playing, its elapsed time advancing). A firmware MediaSupport refuses is judged on the
refusal instead: nothing may reach the guest. Screenshots and the verdict are copied to --evidence/<build>/."""
import json, math, shutil, sqlite3, struct, subprocess, sys, tempfile, unicodedata, wave
from pathlib import Path

APP = Path(__file__).resolve().parents[2]
TITLE, ARTIST, ALBUM, ALBUM_ARTIST = 'Media Sync Tïtle', 'Sync Artist', 'Sync Album', 'Sync Album Artist'
QUADRANTS = [((0.25, 0.25), (200, 40, 40)), ((0.75, 0.25), (40, 180, 60)), ((0.25, 0.75), (40, 60, 200)), ((0.75, 0.75), (240, 220, 30))]
PHOTO = [((0.25, 0.5), (220, 30, 30)), ((0.75, 0.5), (30, 30, 220))]


def nfc(text):
    return unicodedata.normalize('NFC', text) if isinstance(text, str) else text


def fixtures(out):
    from PIL import Image, ImageDraw
    cover = Image.new('RGB', (600, 600))
    draw = ImageDraw.Draw(cover)
    for (x, y), color in QUADRANTS:
        draw.rectangle((int((x - .25) * 600), int((y - .25) * 600), int((x + .25) * 600) - 1, int((y + .25) * 600) - 1), fill=color)
    cover.save(out / 'cover.png')
    with wave.open(str(out / 'tone.wav'), 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes(b''.join(struct.pack('<hh', v, v) for v in (int(8000 * math.sin(2 * math.pi * 440 * i / 44100)) for i in range(44100 * 30))))
    song = out / 'Media Sync Song.mp3'
    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(out / 'tone.wav'), '-i', str(out / 'cover.png'), '-map', '0', '-map', '1',
                    '-c:a', 'libmp3lame', '-b:a', '128k', '-c:v', 'png', '-id3v2_version', '3', '-disposition:v', 'attached_pic',
                    '-metadata:s:v', 'comment=Cover (front)', '-metadata', f'title={TITLE}', '-metadata', f'artist={ARTIST}',
                    '-metadata', f'album={ALBUM}', '-metadata', f'album_artist={ALBUM_ARTIST}', '-metadata', 'track=4/9',
                    '-metadata', 'date=1999', '-metadata', 'genre=Synthpop', str(song)], check=True)
    photo = out / 'Media Sync Photo.png'
    image = Image.new('RGB', (1200, 800))
    ImageDraw.Draw(image).rectangle((0, 0, 599, 799), fill=PHOTO[0][1])
    ImageDraw.Draw(image).rectangle((600, 0, 1199, 799), fill=PHOTO[1][1])
    image.save(photo)
    return song, photo


def close(actual, expected, tolerance=24):
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


def artwork_pixels(afc, artwork_id):
    """The cover as the ArtworkCache keeps it for the item: the largest rendering under its key, decoded."""
    db, pix = afc / 'Purchases_MobileArtworkDB__artwork.db', afc / 'Purchases_MobileArtworkDB__artwork.pix'
    if not db.exists() or not pix.exists():
        return None, 'no ArtworkCache (artwork.db/artwork.pix) on the device'
    with sqlite3.connect(db) as c:
        formats = c.execute('SELECT format, offset, length, width, height, bytesPerRow, bitsPerPixel FROM artwork WHERE key=?',
                            (str(artwork_id),)).fetchall()
    if not formats:
        return None, f'no ArtworkCache rendering under key {artwork_id}'
    # Uncompressed renderings only (the iPad's 3013/3019 are compressed: bytesPerRow 0).
    plain = [f for f in formats if f[5] and f[2] >= f[5] * f[4] and f[6] in (16, 32)]
    if not plain:
        return None, f'no uncompressed ArtworkCache rendering under key {artwork_id}: {formats}'
    fmt, offset, length, width, height, row, bpp = max(plain, key=lambda f: f[3] * f[4])
    data = pix.read_bytes()[offset:offset + length]
    colors = []
    for (x, y), _ in QUADRANTS:
        at = int(y * height) * row + int(x * width) * (bpp // 8)
        if bpp == 16:
            v = data[at] | data[at + 1] << 8   # x1r5g5b5, little-endian
            colors.append(tuple(((v >> s) & 31) * 255 // 31 for s in (10, 5, 0)))
        else:   # 32: BGRA/BGRX little-endian
            colors.append((data[at + 2], data[at + 1], data[at]))
    return {'formats': formats, 'chosen': [fmt, width, height, bpp], 'colors': colors}, None


def ml3_artwork_pixels(afc, db, cache_id):
    """5.x: the cover as ML3 keeps it, the largest JPEG rendering listed for the item's artwork cache ID
    (iTunes_Control/iTunes/Artwork/NN/<key>_<format>.jpg), decoded."""
    from PIL import Image
    formats = db.execute('SELECT format_id, length FROM artwork_info WHERE cache_id=?', (str(cache_id),)).fetchall()
    if not formats:
        return None, f'no artwork_info rows for cache ID {cache_id}'
    files = {f.name.rsplit('_', 1)[-1].split('.')[0]: f for f in afc.glob('iTunes_Control_iTunes_Artwork_*__*.jpg')}
    found = [(length, files[str(fmt)]) for fmt, length in formats if str(fmt) in files]
    if not found:
        return None, f'none of the artwork renderings {formats} read back from iTunes_Control/iTunes/Artwork'
    _, path = max(found)
    with Image.open(path) as im:
        rgb = im.convert('RGB')
        colors = [rgb.getpixel((int(x * im.width), int(y * im.height))) for (x, y), _ in QUADRANTS]
        return {'formats': formats, 'chosen': [path.name, *im.size], 'colors': colors}, None


def judge_library(afc):
    """The song in the 3.x/4.x library (iTunes Library.itlp) or 5.x's ML3 MediaLibrary.sqlitedb, with its artwork."""
    lib, ml3 = afc / 'iTunes_Control_iTunes_iTunes Library.itlp__Library.itdb', afc / 'iTunes_Control_iTunes__MediaLibrary.sqlitedb'
    ml3_db = None
    if ml3.exists():
        with sqlite3.connect(ml3) as db:   # its -wal and -shm were read back beside it
            rows = db.execute('SELECT e.title, a.item_artist, al.album, aa.album_artist, e.year, e.total_time_ms, e.artwork_cache_id '
                              'FROM item i JOIN item_extra e ON e.item_pid=i.item_pid '
                              'LEFT JOIN item_artist a ON a.item_artist_pid=i.item_artist_pid '
                              'LEFT JOIN album al ON al.album_pid=i.album_pid '
                              'LEFT JOIN album_artist aa ON aa.album_artist_pid=i.album_artist_pid '
                              'WHERE i.media_type & 8').fetchall()   # ML3's Song bit (itmedia.c)
        ml3_db = ml3
    elif lib.exists():
        with sqlite3.connect(lib) as db:
            rows = db.execute('SELECT title, artist, album, album_artist, year, total_time_ms, artwork_cache_id FROM item NOT INDEXED '
                              'WHERE is_song=1').fetchall()
    else:
        return {'ok': False, 'why': 'no library (Library.itdb or MediaLibrary.sqlitedb) read back'}
    rows = [tuple(nfc(v) for v in r) for r in rows]
    mine = [r for r in rows if r[0] == nfc(TITLE)]
    if len(mine) != 1:
        return {'ok': False, 'why': f'expected one song titled {TITLE!r}', 'songs': rows}
    title, artist, album, album_artist, year, ms, art = mine[0]
    result = {'song': mine[0]}
    problems = [f'{k}={v!r}' for k, v, want in (('artist', artist, ARTIST), ('album', album, ALBUM),
                                               ('album_artist', album_artist, ALBUM_ARTIST), ('year', year, 1999)) if v != nfc(want)]
    if not (29700 < (ms or 0) < 30400):
        problems.append(f'duration {ms} ms')
    if ml3_db:   # 5.x's Music plays only a row whose FairPlay integrity is set (it-media README)
        with sqlite3.connect(ml3_db) as db:
            if not db.execute('SELECT COUNT(*) FROM item_extra WHERE artwork_cache_id=? AND integrity IS NOT NULL', (art,)).fetchone()[0]:
                problems.append('no item_extra.integrity (Music lists the song but will not play it)')
    if not art:
        problems.append('no artwork_cache_id')
    else:
        if ml3_db:
            with sqlite3.connect(ml3_db) as db:
                pixels, why = ml3_artwork_pixels(afc, db, art)
        else:
            pixels, why = artwork_pixels(afc, art)
        result['artwork'] = pixels
        if why:
            problems.append(why)
        elif not all(close(a, e) for a, (_, e) in zip(pixels['colors'], QUADRANTS)):
            problems.append(f'cover colors {pixels["colors"]}')
    result.update(ok=not problems, why='; '.join(problems))
    return result


def judge_photo(afc):
    from PIL import Image
    shots = sorted(afc.glob('DCIM_100APPLE__IMG_*.JPG'))
    if len(shots) != 1:
        return {'ok': False, 'why': f'{len(shots)} originals in DCIM/100APPLE'}
    with Image.open(shots[0]) as im:
        rgb = im.convert('RGB')
        colors = [rgb.getpixel((int(x * im.width), int(y * im.height))) for (x, y), _ in PHOTO]
        size = im.size
    ok = all(close(a, e, 30) for a, (_, e) in zip(colors, PHOTO))
    return {'ok': ok, 'size': size, 'colors': colors, 'why': '' if ok else f'colors {colors}'}


def played(wav):
    """The song's 440 Hz tone in the guest's recorded audio: seconds of it, loud, at the right pitch."""
    import numpy as np
    if not wav.exists() or wav.stat().st_size < 1000:
        return {'ok': False, 'why': 'no guest audio recorded'}
    with wave.open(str(wav)) as w:
        rate, channels = w.getframerate(), w.getnchannels()
        samples = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').reshape(-1, channels)[:, 0].astype(float)
    seconds = 0
    for start in range(0, len(samples) - rate, rate):
        chunk = samples[start:start + rate]
        peak = np.fft.rfftfreq(len(chunk), 1 / rate)[np.argmax(np.abs(np.fft.rfft(chunk)))]
        if np.sqrt(np.mean(chunk ** 2)) > 500 and abs(peak - 440) < 6:
            seconds += 1
    return {'ok': seconds >= 3, 'tone_seconds': seconds, 'why': '' if seconds >= 3 else f'{seconds} s of the 440 Hz tone'}


def run(args):
    out = Path(tempfile.mkdtemp(prefix='ltm-media-single-'))
    song, photo = fixtures(out)
    work = out / 'work'
    lock = json.loads((args.single / 'device.lock.json').read_text())
    build, version = lock.get('build', ''), lock.get('product_version', '')
    media = [song] + ([photo] if args.with_photo else [])
    cmd = [sys.executable, str(APP / 'tests/sessions/check-sessions.py'), '--single', str(args.single), '--board', args.board,
           '--work', str(work), '--media', *map(str, media), '--media-taps', json.dumps(args.taps)]
    for flag, value in (('--media-tools', args.guest_tools), ('--helper', args.helper), ('--dylib', args.dylib),
                        ('--usbmuxd', args.usbmuxd), ('--frameworks', args.frameworks), ('--firmwarekit', args.firmwarekit),
                        ('--ipad-itpack', args.ipad_itpack)):
        if value:
            cmd += [flag, str(value)]
    wav = out / 'guest-audio.wav'
    if args.taps:   # playback is judged on what the guest played, recorded (never the Mac's speakers)
        cmd += ['--audio-wav', str(wav)]
    print('RUN', ' '.join(cmd), flush=True)
    session = subprocess.run(cmd, timeout=1500)
    events = [json.loads(l) for l in (work / 'driver.jsonl').read_text(errors='replace').splitlines() if l.startswith('{')]
    imports = [e for e in events if e.get('event') == 'media']
    music = next((e for e in events if e.get('event') == 'music'), {})
    board_dir = next((Path(e['dir']).parent for e in events if e.get('event') == 'mediaReadback'), None)
    verdict = {'build': build, 'version': version, 'board': args.board, 'session_exit': session.returncode,
               'imports': imports, 'music': music}
    failures = []
    for e in imports:
        if 'refused' in e:
            continue
        if not e.get('ok'):
            failures.append(f"import {Path(e['source']).name}: {e.get('error')}")
    refused = [e for e in imports if 'refused' in e]
    if refused:
        verdict['refused'] = [e['refused'] for e in refused]
    if board_dir:
        afc = board_dir / 'media-afc'
        if not any('refused' in e for e in imports if e['source'].endswith('.mp3')):
            verdict['library'] = judge_library(afc)
            if not verdict['library']['ok']:
                failures.append('library: ' + verdict['library']['why'])
        if args.with_photo and not any('refused' in e for e in imports if e['source'].endswith('.png')):
            verdict['photo'] = judge_photo(afc)
            if not verdict['photo']['ok']:
                failures.append('photo: ' + verdict['photo']['why'])
    else:
        failures.append('no media read back (the session never reached the media step)')
    if args.taps and not music.get('frontmost', '').startswith(('com.apple.mobileipod', 'com.apple.Music')):
        failures.append(f"Music not frontmost after launch: {music.get('frontmost')!r}")
    if args.taps and not music.get('frontmostAfter', '').startswith(('com.apple.mobileipod', 'com.apple.Music')):
        failures.append(f"Music left the foreground while playing: {music.get('frontmostAfter')!r}")
    if args.taps:
        verdict['playback'] = played(wav)
        if not verdict['playback']['ok']:
            failures.append('playback: ' + verdict['playback']['why'])
    evidence = args.evidence / f'{lock.get("board", args.board)}-{build}'
    evidence.mkdir(parents=True, exist_ok=True)
    if board_dir:
        for png in board_dir.glob('*.png'):
            shutil.copy2(png, evidence / png.name)
    verdict['failures'] = failures
    (evidence / 'verdict.json').write_text(json.dumps(verdict, indent=1, ensure_ascii=False, default=str))
    print(json.dumps(verdict, indent=1, ensure_ascii=False, default=str), flush=True)
    print('EVIDENCE', evidence, flush=True)
    if not args.keep:
        shutil.rmtree(out, ignore_errors=True)
    if failures:
        sys.exit('FAIL: ' + '; '.join(failures))
    print(f'PASS: {args.board} {version} ({build}): the tagged MP3 is in the library with its title, artist, album and cover'
          + (', the photo in Saved Photos' if args.with_photo else '') + (f"; Music played it ({verdict['playback']['tone_seconds']} s of its tone recorded)" if args.taps else ''))
