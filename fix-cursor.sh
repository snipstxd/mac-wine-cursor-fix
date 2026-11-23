#!/bin/bash
# mac-wine-cursor-fix
# Fixes the mouse cursor in Porting Kit / Wineskin games that use a CrossOver-based
# Wine engine (e.g. WS12WineCX26.3_DXMT). Those engines contain two changes that
# break games which hide the cursor:
#   1. In fullscreen, the cursor is ALWAYS hidden (so you can't see it in menus).
#   2. When the game asks to hide the cursor, an arrow is shown instead
#      (so it stays on screen while you play).
# This script finds those two exact pieces of code in the game's winemac.so and
# turns them off (one byte each). It refuses to touch anything it doesn't recognise.
#
# Usage:
#   fix-cursor.sh "/path/to/Game.app"            check and fix
#   fix-cursor.sh --check "/path/to/Game.app"    only check, change nothing
#   fix-cursor.sh --undo "/path/to/Game.app"     put the original file back
set -euo pipefail

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mNote:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

MODE=fix
case "${1:-}" in
    --check) MODE=check; shift ;;
    --undo)  MODE=undo;  shift ;;
    -h|--help|"")
        sed -n '2,18p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
        [ -n "${1:-}" ] && exit 0
        die "Tell me which game app to fix, e.g.:  fix-cursor.sh \"$HOME/Applications/My Game.app\"" ;;
esac

APP="${1:-}"
APP="${APP%/}"
[ -n "$APP" ] || die "Tell me which game app to fix, e.g.:  fix-cursor.sh \"$HOME/Applications/My Game.app\""
[ -d "$APP" ] || die "\"$APP\" does not exist."
NAME="$(basename "$APP" .app)"

# Find the Mac display driver inside the app.
SO=""
for c in "$APP/Contents/SharedSupport/wine/lib/wine/x86_64-unix/winemac.so" \
         "$APP/Contents/Frameworks/wswine.bundle/lib/wine/x86_64-unix/winemac.so" \
         "$APP/Contents/SharedSupport/wine/lib64/wine/x86_64-unix/winemac.so"; do
    if [ -f "$c" ]; then SO="$c"; break; fi
done
if [ -z "$SO" ]; then
    SO="$(find "$APP/Contents" -path '*x86_64-unix/winemac.so' -type f 2>/dev/null | head -1 || true)"
fi
if [ -z "$SO" ]; then say "\"$NAME\" doesn't contain Wine. It's probably a native Mac app, so it doesn't have this bug."; exit 0; fi
BACKUP="$SO.before-cursor-fix"

if [ "$MODE" = undo ]; then
    [ -f "$BACKUP" ] || die "No backup found - \"$NAME\" was never fixed with this tool."
    if pgrep -f "$APP/Contents/.*wineserver" >/dev/null 2>&1; then die "\"$NAME\" is running. Quit it first."; fi
    cp "$BACKUP" "$SO" && rm -f "$BACKUP"
    say "Restored the original file. \"$NAME\" is back to how it was."
    exit 0
fi

# Analyse / patch. Prints one of: FIXED, NEEDS:<n>, UNKNOWN, followed by details.
analyse() {
/usr/bin/perl - "$1" "$2" <<'PERL'
use strict; use warnings;
my ($file, $write) = @ARGV;
open(my $fh, '<:raw', $file) or die "cannot read $file\n";
local $/; my $b = <$fh>; close $fh;

# Parse Mach-O segments so we can follow pointers.
my ($magic, $cputype) = unpack('V V', $b);
if ($magic != 0xfeedfacf || $cputype != 0x01000007) { print "UNKNOWN\nnot an x86_64 Mach-O file\n"; exit 0; }
my ($ncmds) = unpack('V', substr($b, 16, 4));
my @segs; my $off = 32;
for (1..$ncmds) {
    my ($cmd, $size) = unpack('V V', substr($b, $off, 8));
    if ($cmd == 0x19) {
        my ($vm, $vms, $fo, $fs) = unpack('Q< Q< Q< Q<', substr($b, $off + 24, 32));
        push @segs, [$vm, $fs, $fo];
    }
    $off += $size;
}
sub v2f { my $v = shift; for (@segs) { return $v - $_->[0] + $_->[2] if $v >= $_->[0] && $v < $_->[0] + $_->[1]; } return undef; }
sub f2v { my $f = shift; for (@segs) { return $f - $_->[2] + $_->[0] if $f >= $_->[2] && $f < $_->[2] + $_->[1]; } return undef; }
sub cstr { my $v = shift; my $f = v2f($v); return '' unless defined $f; my $e = index($b, "\0", $f); return substr($b, $f, $e - $f); }
sub ptr  { my $v = shift; my $f = v2f($v); return undef unless defined $f; my $p = unpack('Q<', substr($b, $f, 8)); return $p % (2**48); }
sub rip  { my ($f, $len) = @_; my $d = unpack('l<', substr($b, $f + $len - 4, 4)); return f2v($f + $len) + $d; }

my @patches;  # [file offset, from byte, to byte, description]
my $done = 0;

# 1) -[WineApplicationController updateCursor:]
#    mov sel(%rip),%rsi ; call *objc_msgSend ; test %al,%al ; je +7 ; movb $1,OFF(%rbx)
#    where sel == "hasFullscreenWindow"  -> make the je an unconditional jmp.
while ($b =~ /\x48\x8b\x35(.{4})\xff\x15(.{4})\x84\xc0([\x74\xeb])\x07\xc6\x83(.{4})\x01/gs) {
    my $start = $-[0];
    my $sel = ptr(rip($start, 7));
    next unless defined $sel && cstr($sel) eq 'hasFullscreenWindow';
    my $jo = $start + 15;
    if ($3 eq "\xeb") { $done++; } else { push @patches, [$jo, 0x74, 0xeb, 'fullscreen always hides the cursor']; }
}

# 2) macdrv_SetCursor:  mov %r14,%rax ; or %r15,%rax ; jne +N ; lea cfstr(%rip),%rdi
#    where cfstr == "arrowCursor"  -> make the jne an unconditional jmp.
while ($b =~ /\x4c\x89\xf0\x4c\x09\xf8([\x75\xeb])(.)\x48\x8d\x3d(.{4})/gs) {
    my $start = $-[0];
    my $cf = rip($start + 8, 7);
    my $cfo = v2f($cf); next unless defined $cfo;
    my $sp = unpack('Q<', substr($b, $cfo + 16, 8)) % (2**48);
    next unless cstr($sp) eq 'arrowCursor';
    if ($1 eq "\xeb") { $done++; } else { push @patches, [$start + 6, 0x75, 0xeb, 'hidden cursor replaced by an arrow']; }
}

my $total = $done + @patches;
if ($total != 2) { print "UNKNOWN\nfound $total of the 2 expected code locations\n"; exit 0; }
if (!@patches) { print "FIXED\n"; exit 0; }
print "NEEDS:" . scalar(@patches) . "\n";
print "  - $_->[3]\n" for @patches;
if ($write) {
    for (@patches) { substr($b, $_->[0], 1) = chr($_->[2]); }
    open(my $o, '>:raw', "$file.tmp") or die "cannot write\n"; print $o $b; close $o;
    rename("$file.tmp", $file) or die "cannot replace file\n";
}
PERL
}

RESULT="$(analyse "$SO" 0)"
STATUS="$(printf '%s\n' "$RESULT" | head -1)"
DETAILS="$(printf '%s\n' "$RESULT" | tail -n +2)"

case "$STATUS" in
    FIXED)
        say "\"$NAME\" is already fixed. Nothing to do."
        exit 0 ;;
    UNKNOWN)
        say "\"$NAME\" uses a Wine engine without this cursor bug (or one this tool doesn't recognise)."
        echo "    Nothing was changed. ($DETAILS)"
        exit 0 ;;
    NEEDS:*)
        say "\"$NAME\" has the cursor bug:"
        printf '%s\n' "$DETAILS" ;;
    *) die "Unexpected result: $RESULT" ;;
esac

if [ "$MODE" = check ]; then
    echo "    Run without --check to fix it."
    exit 0
fi

if pgrep -f "$APP/Contents/.*wineserver" >/dev/null 2>&1; then
    die "\"$NAME\" is running. Quit it first, then run this again."
fi

[ -f "$BACKUP" ] || cp "$SO" "$BACKUP"
analyse "$SO" 1 >/dev/null
chmod 755 "$SO"

[ "$(analyse "$SO" 0 | head -1)" = FIXED ] || die "Something went wrong - restore with: fix-cursor.sh --undo \"$APP\""
say "Fixed! Start \"$NAME\" again. The cursor should now show in menus and hide while you play."
echo "    (Original saved next to it. Undo any time with --undo.)"
