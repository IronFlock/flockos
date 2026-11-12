#!/usr/bin/env bats
# The screen (docs/build.md, "The screen"; docs/kiosk-plan.md): the splash in
# the EFI images, the display setting and the device's own splash picture,
# run against a temporary directory instead of a device.

repo="$BATS_TEST_DIRNAME/../.."
lib="$repo/overlay/usr/lib/ironflockos"
units="$repo/overlay/usr/lib/systemd/system"
theme_src="$repo/overlay/usr/share/plymouth/themes/ironflockos"

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/screen" "$tmp/esp/EFI/BOOT" "$tmp/run" "$tmp/theme" "$tmp/bin"
  cp "$theme_src/ironflockos.plymouth" "$theme_src/ironflockos.script" "$tmp/theme/"
  cp "$repo/docs/assets/ironflock-splash.png" "$tmp/theme/ironflock.png"
  # grub-editenv FILE list | set KEY=VALUE | unset KEY, on a plain file.
  cat >"$tmp/bin/grub-editenv" <<'SH'
#!/bin/bash
f=$1
touch "$f"
case "$2" in
  list) cat "$f" ;;
  set) grep -v "^${3%%=*}=" "$f" >"$f.new" || true; echo "$3" >>"$f.new"; mv "$f.new" "$f" ;;
  unset) grep -v "^$3=" "$f" >"$f.new" || true; mv "$f.new" "$f" ;;
esac
SH
  chmod +x "$tmp/bin/grub-editenv"
}
teardown() { rm -rf "$tmp"; }

# splash [ARGS...]: the splash script on the temporary device.
splash() {
  PATH="$tmp/bin:$PATH" IRONFLOCKOS_SCREEN=$tmp/screen IRONFLOCKOS_EFI_BOOT=$tmp/esp/EFI/BOOT IRONFLOCKOS_THEME=$tmp/theme \
    IRONFLOCKOS_RUN=$tmp/run IRONFLOCKOS_SPLASH_BIND=no run bash "$lib/splash" "$@"
}

# be32 N: N as four bytes, big-endian, as printf %b escapes.
be32() {
  printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 >> 24 & 255)) $(($1 >> 16 & 255)) $(($1 >> 8 & 255)) $(($1 & 255))
}

# chunk TYPE DATA: a PNG chunk with DATA (printf %b escapes); the CRC is
# left zero, which the check does not read.
chunk() {
  local len
  len=$(printf '%b' "$2" | wc -c | tr -d ' ')
  printf '%b' "$(be32 "$len")$1$2\\x00\\x00\\x00\\x00"
}

# png FILE WIDTH HEIGHT [CHUNK...]: the chunks of an 8-bit RGB PNG: IHDR, the
# CHUNKs named, IDAT, IEND.
png() {
  local f=$1 w=$2 h=$3 c
  shift 3
  {
    printf '\x89PNG\r\n\x1a\n'
    chunk IHDR "$(be32 "$w")$(be32 "$h")\\x08\\x02\\x00\\x00\\x00"
    for c in "$@"; do chunk "$c" 'abcd'; done
    chunk IDAT 'pixels'
    chunk IEND ''
  } >"$f"
}

# listing: the names in the archive, by an independent cpio.
listing() {
  (cd "$tmp" && cpio -it --quiet <"$tmp/esp/EFI/BOOT/splash.cpio" 2>/dev/null)
}

# unpack DIR: the archive unpacked by an independent cpio into DIR.
unpack() {
  mkdir -p "$1"
  (cd "$1" && cpio -id --quiet <"$tmp/esp/EFI/BOOT/splash.cpio" 2>/dev/null)
}

@test "the default picture is IronFlock's white logo at 320x320 pixels, a PNG the splash takes" {
  f=$repo/docs/assets/ironflock-splash.png
  splash check-png "$f"
  [ "$status" -eq 0 ]
  # IHDR: 320x320, 8 bits, RGBA (transparent around the logo).
  [ "$(od -An -v -tx1 -j 16 -N 10 "$f" | tr -d ' \n')" = 00000140000001400806 ]
}

@test "the theme draws the picture by the contract: centred, own size, smaller to fit, no spinner, none and fade" {
  s=$theme_src/ironflockos.script
  grep -qx 'ModuleName=script' "$theme_src/ironflockos.plymouth"
  grep -qx 'Theme=ironflockos' "$repo/overlay/etc/plymouth/plymouthd.conf"
  # The settings block ironflockos-splash writes anew.
  [ "$(sed -n '1p' "$s")" = '// --- settings ---' ]
  grep -qx '// --- end of settings ---' "$s"
  grep -qx 'animation = "fade";' "$s"
  # The device's picture first, else IronFlock's logo.
  grep -q 'Image("splash.png")' "$s"
  grep -q 'Image("ironflock.png")' "$s"
  # Centred, scaled only when larger than the screen.
  grep -q 'Math.Int((Window.GetWidth() - shown.GetWidth()) / 2)' "$s"
  grep -q 'if (shown.GetWidth() > Window.GetWidth() || shown.GetHeight() > Window.GetHeight())' "$s"
  grep -q 'SetDisplayHotplugFunction(layout)' "$s"
  # The fade only at the start, the message line below the picture.
  grep -q 'if (animation == "fade" && Plymouth.GetMode() == "boot")' "$s"
  grep -q 'SetDisplayMessageFunction(display_message)' "$s"
  ! grep -v '^ *//' "$s" | grep -qi 'progress\|throbber\|spinner'
}

@test "data-layout makes the screen folder, owned by root, before Docker" {
  IRONFLOCKOS_DATA=$tmp/data run sh "$lib/data-layout"
  [ "$status" -eq 0 ]
  [ "$(ls -ld "$tmp/data/ironflockos/screen" | cut -c1-10)" = drwxr-xr-x ]
  grep -qx 'Before=local-fs.target shutdown.target' "$units/ironflockos-data-layout.service"
}

@test "splash: no files, no archive; a picture and its settings become splash.cpio for the next boot" {
  splash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$tmp/esp/EFI/BOOT/splash.cpio" ]
  png "$tmp/screen/splash.png" 640 400
  printf 'background=#204060  # dark blue\r\nanimation=None\n' >"$tmp/screen/splash.conf"
  splash
  [ "$status" -eq 0 ]
  [[ "$output" == *"the splash from the next boot on: the device's picture, background #204060, animation none"* ]]
  # Plymouth's theme folder in the initramfs, the picture first; nothing else.
  [ "$(listing | tr '\n' ' ')" = "usr/share/plymouth/themes/ironflockos/splash.png usr/share/plymouth/themes/ironflockos/ironflockos.script " ]
  unpack "$tmp/x"
  d=$tmp/x/usr/share/plymouth/themes/ironflockos
  cmp "$d/splash.png" "$tmp/screen/splash.png"
  grep -qx 'background_red = 32;' "$d/ironflockos.script"
  grep -qx 'background_green = 64;' "$d/ironflockos.script"
  grep -qx 'background_blue = 96;' "$d/ironflockos.script"
  grep -qx 'animation = "none";' "$d/ironflockos.script"
  # The rest is the image's own script.
  diff <(sed '1,/^\/\/ --- end of settings ---$/d' "$d/ironflockos.script") <(sed '1,/^\/\/ --- end of settings ---$/d' "$theme_src/ironflockos.script")
  # No temporary file left on the partition or in /run.
  [ "$(ls -A "$tmp/esp/EFI/BOOT" | tr '\n' ' ')" = "splash.cpio splash.env " ]
  # GRUB's colour (WP-8.7); with animation=none no picture until the screen
  # is taken after a boot.
  grep -qx 'IRONFLOCKOS_SPLASH_BACKGROUND=#204060' "$tmp/esp/EFI/BOOT/splash.env"
  [ -z "$(ls -A "$tmp/run" | grep -vE '^splash-(theme|booted)$')" ]
}

@test "splash: the same files make the same archive, which is not written again" {
  png "$tmp/screen/splash.png" 64 48
  splash
  [ "$status" -eq 0 ]
  cp "$tmp/esp/EFI/BOOT/splash.cpio" "$tmp/first.cpio"
  touch -t 202001010000 "$tmp/esp/EFI/BOOT/splash.cpio"
  sleep 1
  touch "$tmp/screen/splash.png"
  splash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$tmp/first.cpio" "$tmp/esp/EFI/BOOT/splash.cpio"
  [ -z "$(find "$tmp/esp/EFI/BOOT/splash.cpio" -newer "$tmp/first.cpio")" ]
}

@test "splash: splash.conf alone sets the colour for IronFlock's logo; removing both brings the image's splash back" {
  printf 'background=#FFFFFF\n' >"$tmp/screen/splash.conf"
  splash
  [ "$status" -eq 0 ]
  [[ "$output" == *"IronFlock's logo, background #ffffff, animation fade"* ]]
  [ "$(listing | tr '\n' ' ')" = "usr/share/plymouth/themes/ironflockos/ironflockos.script " ]
  rm "$tmp/screen/splash.conf"
  splash
  [ "$status" -eq 0 ]
  [[ "$output" == *"IronFlock's logo from the next boot on"* ]]
  [ ! -e "$tmp/esp/EFI/BOOT/splash.cpio" ]
  [ ! -e "$tmp/run/splash-theme" ]
}

@test "splash: what the contract refuses is refused, says why, and the splash stays as it was" {
  png "$tmp/screen/splash.png" 64 48
  splash
  cp "$tmp/esp/EFI/BOOT/splash.cpio" "$tmp/good.cpio"
  refused() {
    splash
    [ "$status" -eq 1 ]
    [[ "$output" == *"refused: $1; the splash stays as it was"* ]]
    cmp "$tmp/good.cpio" "$tmp/esp/EFI/BOOT/splash.cpio"
  }
  echo 'not a picture' >"$tmp/screen/splash.png"
  refused "splash.png is not a PNG"
  head -c $((4 * 1024 * 1024 + 1)) /dev/zero >"$tmp/screen/splash.png"
  refused "splash.png is larger than 4 MiB"
  png "$tmp/screen/splash.png" 3841 100
  refused "splash.png is 3841x100 pixels, more than 3840x2160"
  png "$tmp/screen/splash.png" 100 2161
  refused "splash.png is 100x2161 pixels, more than 3840x2160"
  png "$tmp/screen/splash.png" 64 48 tEXt
  refused "splash.png has the chunk tEXt: only IHDR, PLTE, tRNS, IDAT and IEND are taken"
  png "$tmp/screen/splash.png" 64 48 iCCP
  refused "splash.png has the chunk iCCP: only IHDR, PLTE, tRNS, IDAT and IEND are taken"
  png "$tmp/screen/splash.png" 64 48
  head -c 40 "$tmp/screen/splash.png" >"$tmp/cut.png" && mv "$tmp/cut.png" "$tmp/screen/splash.png"
  refused "splash.png ends inside a chunk"
  png "$tmp/screen/splash.png" 64 48
  echo trailing >>"$tmp/screen/splash.png"
  refused "splash.png has data after IEND"
  png "$tmp/screen/splash.png" 0 48
  refused "splash.png has no pixels"
  ln -sf /etc/hostname "$tmp/screen/splash.png"
  refused "splash.png is not a file"
  rm "$tmp/screen/splash.png"
  mkdir "$tmp/screen/splash.png"
  refused "splash.png is not a file"
  rmdir "$tmp/screen/splash.png"
  png "$tmp/screen/splash.png" 64 48
  printf 'background=#204060\ncolour=red\n' >"$tmp/screen/splash.conf"
  refused "splash.conf: line 2: unknown key colour"
  printf 'background=blue\n' >"$tmp/screen/splash.conf"
  refused "splash.conf: line 1: background must be a colour #RRGGBB"
  printf 'animation=spin\n' >"$tmp/screen/splash.conf"
  refused "splash.conf: line 1: animation must be none or fade"
  printf 'animation=fade\nanimation=none\n' >"$tmp/screen/splash.conf"
  refused "splash.conf: line 2: animation is given twice"
  printf 'just words\n' >"$tmp/screen/splash.conf"
  refused "splash.conf: line 1 is not a key=value line"
  printf 'animation=fade\0\n' >"$tmp/screen/splash.conf"
  refused "splash.conf holds a NUL byte"
}

@test "splash: the PNG's own rules: IHDR first, a palette picture with its palette, PLTE and tRNS before the image data" {
  for case in "IHDR-late" "palette" "plte-late" "idat-apart" "colour"; do
    {
      printf '\x89PNG\r\n\x1a\n'
      case "$case" in
        IHDR-late) chunk IDAT x ;;
        palette) chunk IHDR "$(be32 8)$(be32 8)\\x08\\x03\\x00\\x00\\x00" && chunk IDAT x ;;
        plte-late) chunk IHDR "$(be32 8)$(be32 8)\\x08\\x03\\x00\\x00\\x00" && chunk IDAT x && chunk PLTE 'abc' ;;
        idat-apart) chunk IHDR "$(be32 8)$(be32 8)\\x08\\x03\\x00\\x00\\x00" && chunk PLTE 'abc' && chunk IDAT x && chunk tRNS a && chunk IDAT y ;;
        colour) chunk IHDR "$(be32 8)$(be32 8)\\x10\\x03\\x00\\x00\\x00" && chunk IDAT x ;;
      esac
      chunk IEND ''
    } >"$tmp/p.png"
    splash check-png "$tmp/p.png"
    [ "$status" -eq 1 ]
    case "$case" in
      IHDR-late) [ "$output" = "splash: splash.png does not start with IHDR" ] ;;
      palette) [ "$output" = "splash: splash.png has a palette colour type and no PLTE" ] ;;
      plte-late) [ "$output" = "splash: splash.png has PLTE after its image data" ] ;;
      idat-apart) [ "$output" = "splash: splash.png has tRNS after its image data" ] ;;
      colour) [ "$output" = "splash: splash.png has colour type 3 with 16 bits, which PNG does not know" ] ;;
    esac
  done
  {
    printf '\x89PNG\r\n\x1a\n'
    chunk IHDR "$(be32 8)$(be32 8)\\x08\\x03\\x00\\x00\\x01"
    chunk PLTE 'abc'
    chunk tRNS a
    chunk IDAT x
    chunk IDAT y
    chunk IEND ''
  } >"$tmp/p.png"
  splash check-png "$tmp/p.png"
  [ "$status" -eq 0 ]
}

@test "splash: the app's temporary file changes nothing; only the two names are read" {
  png "$tmp/screen/.splash.png.partial" 64 48
  echo 'background=#ffffff' >"$tmp/screen/.splash.conf.partial"
  png "$tmp/screen/other.png" 64 48
  splash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$tmp/esp/EFI/BOOT/splash.cpio" ]
  # The rename makes it the splash.
  mv "$tmp/screen/.splash.png.partial" "$tmp/screen/splash.png"
  splash
  [ "$status" -eq 0 ]
  [ -e "$tmp/esp/EFI/BOOT/splash.cpio" ]
  [ "$(listing | head -n 1)" = usr/share/plymouth/themes/ironflockos/splash.png ]
}

@test "splash: the theme for the shutdown gets the archive's files; a damaged archive leaves the image's theme" {
  png "$tmp/screen/splash.png" 64 48
  printf 'animation=none\n' >"$tmp/screen/splash.conf"
  splash
  [ "$status" -eq 0 ]
  live=$tmp/run/splash-theme
  cmp "$live/splash.png" "$tmp/screen/splash.png"
  grep -qx 'animation = "none";' "$live/ironflockos.script"
  cmp "$live/ironflock.png" "$repo/docs/assets/ironflock-splash.png"
  cmp "$live/ironflockos.plymouth" "$theme_src/ironflockos.plymouth"
  # Random bytes on the partition (the files on /data refused): no theme of
  # its own, and the boot still shows IronFlock's logo.
  head -c 4096 /dev/urandom >"$tmp/esp/EFI/BOOT/splash.cpio"
  echo broken >"$tmp/screen/splash.png"
  splash
  [ "$status" -eq 1 ]
  [[ "$output" == *"splash.cpio is damaged: the next boot shows IronFlock's logo"* ]]
  [ ! -e "$live" ]
}

@test "splash: without the IRONFLOCKOS partition nothing changes, and it says so" {
  rm -rf "$tmp/esp"
  png "$tmp/screen/splash.png" 64 48
  splash
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not there (the IRONFLOCKOS partition is not mounted): nothing changes"* ]]
}

@test "splash's units: at every boot and on the two names, not required by anything, EFI devices only, masked on the installer" {
  grep -qx 'PathChanged=/data/ironflockos/screen/splash.png' "$units/ironflockos-splash.path"
  grep -qx 'PathChanged=/data/ironflockos/screen/splash.conf' "$units/ironflockos-splash.path"
  [ "$(grep -c '^Path' "$units/ironflockos-splash.path")" -eq 2 ]
  grep -qx 'Unit=ironflockos-splash.service' "$units/ironflockos-splash.path"
  # It runs again for the path unit: no RemainAfterExit.
  ! grep -q RemainAfterExit "$units/ironflockos-splash.service"
  grep -qx 'ExecStart=/usr/lib/ironflockos/splash' "$units/ironflockos-splash.service"
  ! grep -qE '^(Requires|BindsTo|Requisite|RequiredBy)=' "$units/ironflockos-splash.service" "$units/ironflockos-display.service"
  grep -qx 'PathChanged=/data/ironflockos/display.conf' "$units/ironflockos-display.path"
  c=$repo/build/customize.sh
  grep -qx '    systemctl --root="$ROOT" enable ironflockos-splash.service ironflockos-display.service ironflockos-splash-capture.service' "$c"
  grep -qx '    ln -sfn /data/ironflockos/display.conf "$ROOT/etc/ironflockos/display.conf"' "$c"
  grep -q 'mask ironflockos-splash.service ironflockos-splash.path' "$c"
  grep -q '    ironflockos-display.service ironflockos-display.path' "$c"
}

# display: the display script on the temporary device.
display() {
  PATH="$tmp/bin:$PATH" IRONFLOCKOS_DISPLAY_CONF=$tmp/display.conf IRONFLOCKOS_GRUBENV=$tmp/grubenv run bash "$lib/display"
}

@test "display: boot=text goes into grubenv for GRUB, boot=splash or no file takes it out" {
  printf 'ORDER=A B\n' >"$tmp/grubenv"
  display
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/grubenv")" = "ORDER=A B" ]
  printf '# the boot messages\nboot=text\n' >"$tmp/display.conf"
  display
  [ "$status" -eq 0 ]
  grep -qx IRONFLOCKOS_BOOT=text "$tmp/grubenv"
  [[ "$output" == *"the boot messages instead of the splash, from the next boot on"* ]]
  display
  [ "$status" -eq 0 ]
  [ "$output" = "display: boot=text" ]
  printf 'boot=splash\r\n' >"$tmp/display.conf"
  display
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/grubenv")" = "ORDER=A B" ]
  printf 'boot=text\n' >"$tmp/display.conf"
  display
  rm "$tmp/display.conf"
  display
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/grubenv")" = "ORDER=A B" ]
}

@test "display: a file it does not understand changes nothing and says why" {
  printf 'IRONFLOCKOS_BOOT=text\n' >"$tmp/grubenv"
  for content in 'boot=quiet' 'screen=on' 'boot text' 'boot=splash\nboot=text'; do
    printf "$content\n" >"$tmp/display.conf"
    display
    [ "$status" -eq 1 ]
    [[ "$output" == *"display: refused $tmp/display.conf: "*"; the boot stays as it was"* ]]
    grep -qx IRONFLOCKOS_BOOT=text "$tmp/grubenv"
  done
}

@test "GRUB: the splash by default; boot=text, or ironflockos.boot=text on the command line, boots as before" {
  . "$repo/build/lib.sh"
  load_conf "$repo/targets/amd64-efi/target.conf"
  cfg=$(render "$repo/targets/amd64-efi/grub/grub.cfg")
  echo "$cfg" | grep -qx 'set IRONFLOCKOS_BOOT=splash'
  # The default comes before grubenv, which may name text.
  [ "$(echo "$cfg" | grep -n 'set IRONFLOCKOS_BOOT=splash' | cut -d: -f1)" -lt "$(echo "$cfg" | grep -n '^load_env' | cut -d: -f1)" ]
  echo "$cfg" | grep -qF 'if [ "${IRONFLOCKOS_BOOT}" = text ]; then set splash=no; fi'
  echo "$cfg" | grep -qF "if regexp ' ironflockos\\.boot=text ' \" \${IRONFLOCKOS_CMDLINE} \"; then set splash=no; fi"
  echo "$cfg" | grep -qx '    set SPLASH_CMDLINE="quiet splash plymouth.ignore-serial-consoles plymouth.force-frame-buffer-on-boot vt.global_cursor_default=0 fbcon=map:9"'
  echo "$cfg" | grep -qx '    set SPLASH_CMDLINE="plymouth.enable=0"'
  # The menu is hidden with the splash only; Esc during the timeout shows it.
  [ "$(echo "$cfg" | grep -c 'timeout_style')" -eq 1 ]
  echo "$cfg" | grep -qx '    set timeout_style=hidden'
  echo "$cfg" | grep -qx 'set timeout=2'
  # The device's own picture after the slot's initramfs, in both entries.
  echo "$cfg" | grep -qF '    if [ -f ${prefix}/splash.cpio ]; then set splash_initrd=${prefix}/splash.cpio; fi'
  [ "$(echo "$cfg" | grep -c 'initrd.img ${splash_initrd}$')" -eq 2 ]
  echo "$cfg" | grep -q '^set CMDLINE=".* ${SPLASH_CMDLINE} ${IRONFLOCKOS_RT_CMDLINE} ${IRONFLOCKOS_CMDLINE}"$'
}

@test "the screen in the image: Plymouth on the EFI targets only, its theme before the initramfs, the installer on text" {
  . "$repo/build/lib.sh"
  for t in amd64-efi arm64-efi; do
    for p in plymouth plymouth-label fontconfig; do
      read_list "$repo/targets/$t/packages" | grep -qx "$p"
    done
  done
  ! read_list "$repo/profiles/base/packages" "$repo/profiles/base/packages.debian" "$repo/targets/rpi-arm64/packages" "$repo/targets/jetson-orin/packages" 2>/dev/null | grep -q '^plymouth'
  m=$repo/build/mkrootfs.sh
  grep -qF 'upload $src/docs/assets/ironflock-splash.png $theme/ironflock.png' "$m"
  grep -qF 'upload $src/overlay/etc/plymouth/plymouthd.conf /etc/plymouth/plymouthd.conf' "$m"
  grep -qF -- "--chrooted-customize-hook='update-initramfs -u -k all'" "$m"
  # The theme's hooks come before the nvidia variant's, which makes the
  # initramfs again with them in place.
  [ "$(grep -n 'update-initramfs -u -k all' "$m" | cut -d: -f1)" -lt "$(grep -n 'ironflockos-nvidia-modules.sh \$NVIDIA_DRIVER_VERSION' "$m" | cut -d: -f1)" ]
  grep -qF 'grub-editenv "$esp_dir/EFI/BOOT/grubenv" set IRONFLOCKOS_BOOT=text' "$repo/build/mkimage.sh"
}

@test "with the splash, tty1 belongs to the screen and Plymouth leaves the picture on it" {
  grep -qx 'ConditionKernelCommandLine=!splash' "$units/getty@tty1.service.d/ironflockos-splash.conf"
  q=$units/plymouth-quit.service.d/ironflockos.conf
  [ "$(grep '^ExecStart=' "$q" | tr '\n' '|')" = "ExecStart=|ExecStart=-/usr/bin/plymouth quit --retain-splash|" ]
}

# --- the usual keys (WP-8.2) -------------------------------------------------

yescrypt='$y$j9T$abcdefghijklmnopqrstuv$ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq'
sha512='$6$saltsalt$ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh'

# device_with_user: a root with the enrolled user owner (uid 1001, sudo rule,
# locked) beside root and a system account, and enroll's record of it.
device_with_user() {
  mkdir -p "$tmp/root/etc/sudoers.d" "$tmp/data"
  printf 'root:x:0:0::/root:/bin/bash\nsshd:x:100:65534::/run/sshd:/usr/sbin/nologin\nowner:x:1001:1001::/home/owner:/bin/bash\n' >"$tmp/root/etc/passwd"
  printf 'root:*:20000:0:99999:7:::\nsshd:!:20000::::::\nowner:!:20000:0:99999:7:::\n' >"$tmp/root/etc/shadow"
  chmod 0640 "$tmp/root/etc/shadow"
  echo 'owner ALL=(ALL) NOPASSWD:ALL' >"$tmp/root/etc/sudoers.d/ironflock-owner"
  echo '{"user": {"name": "owner", "created": true}}' >"$tmp/installed.json"
}

console_password() {
  IRONFLOCKOS_CONSOLE_PASSWORD=$tmp/data/console-password IRONFLOCKOS_INIT_RECORD=$tmp/installed.json \
    IRONFLOCKOS_ROOT=$tmp/root run bash "$lib/console-password"
}

field() { awk -F: -v u="$1" '$1 == u { print $2 }' "$tmp/root/etc/shadow"; }

@test "console-password: a yescrypt or SHA-512 hash becomes the enrolled user's password, nobody else's; removing it locks it again" {
  device_with_user
  console_password
  [ "$status" -eq 0 ]
  [ "$(field owner)" = '!' ]
  (umask 077 && printf '%s\n' "$yescrypt" >"$tmp/data/console-password")
  console_password
  [ "$status" -eq 0 ]
  [ "$output" = "console-password: the console password is owner's" ]
  [ "$(field owner)" = "$yescrypt" ]
  [ "$(field root)" = '*' ]
  [ "$(field sshd)" = '!' ]
  [ "$(ls -ln "$tmp/root/etc/shadow" | cut -c1-10)" = -rw-r----- ]
  (umask 077 && printf '%s' "$sha512" >"$tmp/data/console-password")
  console_password
  [ "$status" -eq 0 ]
  [ "$(field owner)" = "$sha512" ]
  rm "$tmp/data/console-password"
  console_password
  [ "$status" -eq 0 ]
  [ "$(field owner)" = '!' ]
  [ "$(grep -c . "$tmp/root/etc/shadow")" -eq 3 ]
}

@test "console-password: what is not one hash of the two kinds, or not root's 0600 file, is refused and the password locked" {
  device_with_user
  for content in '' 'secret' '$1$salt$abcdefghijklmnopqrstuv' "\$y\$j9T\$x\$short" "$yescrypt
$yescrypt" '!locked' "$yescrypt:0:0"; do
    (umask 077 && printf '%s\n' "$sha512" >"$tmp/data/console-password")
    console_password
    [ "$(field owner)" = "$sha512" ]
    (umask 077 && printf '%s\n' "$content" >"$tmp/data/console-password")
    console_password
    [ "$status" -eq 1 ]
    [[ "$output" == "console-password: refused $tmp/data/console-password: "*"; owner's password is locked" ]]
    [ "$(field owner)" = '!' ]
    [ "$(field root)" = '*' ]
  done
  printf '%s\n' "$sha512" >"$tmp/data/console-password"
  chmod 0644 "$tmp/data/console-password"
  console_password
  [ "$status" -eq 1 ]
  [[ "$output" == *"its mode is not 0600"* ]]
}

@test "console-password: only an account of a person with enroll's sudo rule, never root; none before the enrollment" {
  device_with_user
  (umask 077 && printf '%s\n' "$yescrypt" >"$tmp/data/console-password")
  rm "$tmp/installed.json"
  console_password
  [ "$status" -eq 0 ]
  [[ "$output" == *"waits for the enrollment"* ]]
  [ "$(field owner)" = '!' ]
  for name in root sshd nobody; do
    echo "{\"user\": {\"name\": \"$name\"}}" >"$tmp/installed.json"
    console_password
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an account the console password is for: nothing changes"* ]]
  done
  echo '{"user": {"name": "owner"}}' >"$tmp/installed.json"
  rm "$tmp/root/etc/sudoers.d/ironflock-owner"
  console_password
  [ "$status" -eq 1 ]
  [ "$(field owner)" = '!' ]
  [ "$(field root)" = '*' ]
}

@test "console-password's units: after enroll, before the login prompts, again when the file changes; masked on the installer" {
  grep -qx 'After=local-fs.target data.mount ironflockos-enroll.service' "$units/ironflockos-console-password.service"
  grep -qx 'PathChanged=/data/ironflockos/console-password' "$units/ironflockos-console-password.path"
  grep -qx 'After=ironflockos-console-password.service' "$units/getty@.service.d/ironflockos-console-password.conf"
  ! grep -q RemainAfterExit "$units/ironflockos-console-password.service"
  grep -qx '  systemctl --root="$ROOT" enable ironflockos-console-password.service' "$repo/build/customize.sh"
  grep -q 'ironflockos-console-password.service ironflockos-console-password.path$' "$repo/build/customize.sh"
  # SSH stays key-only and root's login refused.
  grep -qx 'PasswordAuthentication no' "$repo/overlay/etc/ssh/sshd_config.d/10-ironflockos.conf"
  grep -qx 'KbdInteractiveAuthentication no' "$repo/overlay/etc/ssh/sshd_config.d/10-ironflockos.conf"
  grep -qx 'PermitRootLogin no' "$repo/overlay/etc/ssh/sshd_config.d/10-ironflockos.conf"
}

@test "GRUB's menu: the slot, its fallback, one start with messages, the firmware's setup" {
  . "$repo/build/lib.sh"
  load_conf "$repo/targets/amd64-efi/target.conf"
  cfg=$(render "$repo/targets/amd64-efi/grub/grub.cfg" | grep -v '^ *#')
  [ "$(echo "$cfg" | grep -o 'menuentry "[^"]*"' | tr '\n' '|')" = 'menuentry "IronFlockOS slot ${slot}"|menuentry "IronFlockOS slot ${other} (fallback)"|menuentry "Start with messages"|menuentry "Firmware setup"|' ]
  echo "$cfg" | grep -qx 'set default=0'
  echo "$cfg" | grep -qx '    set fallback=1'
  # Messages for this boot: the text parameters, the setting untouched, no
  # splash archive.
  echo "$cfg" | grep -qx 'set TEXT_CMDLINE="${BASE_CMDLINE} plymouth.enable=0 ${IRONFLOCKOS_RT_CMDLINE} ${IRONFLOCKOS_CMDLINE}"'
  entry=$(echo "$cfg" | sed -n '/^menuentry "Start with messages"/,/^}/p')
  [[ "$entry" == *'rauc.slot=${slot} ${TEXT_CMDLINE}'* ]]
  [[ "$entry" != *splash* ]]
  ! echo "$cfg" | grep -q 'save_env.*BOOT'
  echo "$cfg" | grep -qx 'if fwsetup --is-supported; then'
  echo "$cfg" | grep -qx '        fwsetup'
}

# --- messages on the splash (WP-8.3) -----------------------------------------

# fake_plymouth RUNNING: a plymouth that answers --ping when RUNNING is yes
# and writes what it is asked to show into $tmp/shown.
fake_plymouth() {
  cat >"$tmp/bin/plymouth" <<SH
#!/bin/sh
case "\$1" in
  --ping) [ "$1" = yes ] ;;
  display-message) echo "\${2#--text=}" >>"$tmp/shown" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$tmp/bin/plymouth"
}

@test "screen-message: the text goes to Plymouth while it runs; without it nothing happens and nothing fails" {
  fake_plymouth yes
  PATH="$tmp/bin:$PATH" run sh "$lib/screen-message" "Not enrolled: put it there."
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/shown")" = "Not enrolled: put it there." ]
  fake_plymouth no
  PATH="$tmp/bin:$PATH" run sh "$lib/screen-message" "Another"
  [ "$status" -eq 0 ]
  [ "$(cat "$tmp/shown")" = "Not enrolled: put it there." ]
  rm "$tmp/bin/plymouth"
  PATH="$tmp/bin:/usr/bin:/bin" run sh "$lib/screen-message" "Another"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "what the image says to a person at the device also goes to the splash" {
  fake_plymouth yes
  # enroll without any .flock: unenrolled, and the splash says what to do.
  mkdir -p "$tmp/esp" "$tmp/agent" "$tmp/state" "$tmp/run2"
  PATH="$tmp/bin:$PATH" IRONFLOCKOS_SCREEN_MESSAGE=$lib/screen-message IRONFLOCKOS_ESP=$tmp/esp \
    IRONFLOCKOS_AGENT_DIR=$tmp/agent IRONFLOCKOS_STATE=$tmp/state IRONFLOCKOS_RUN=$tmp/run2 \
    IRONFLOCKOS_IRONFLOCK=/bin/false run bash "$lib/enroll"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the device stays unenrolled"* ]]
  [ "$(tail -n 1 "$tmp/shown")" = "Not enrolled: put this device's .flock file on its IRONFLOCKOS partition." ]
  PATH="$tmp/bin:$PATH" IRONFLOCKOS_SCREEN_MESSAGE=$lib/screen-message IRONFLOCKOS_RUN=$tmp/run2 \
    IRONFLOCKOS_DATA=$tmp/data2 run sh "$lib/data-missing"
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$tmp/shown")" = "The data partition could not be mounted: the apps do not run." ]
  rm "$tmp/run2/data-missing"
  mkdir -p "$tmp/apps" "$tmp/data2/apps"
  PATH="$tmp/bin:$PATH" IRONFLOCKOS_SCREEN_MESSAGE=$lib/screen-message IRONFLOCKOS_APPS=$tmp/apps \
    IRONFLOCKOS_DATA=$tmp/data2 IRONFLOCKOS_RUN=$tmp/run2 run sh "$lib/apps-check"
  [ "$status" -eq 1 ]
  [ "$(tail -n 1 "$tmp/shown")" = "The apps' data is not on the data partition: it is lost at the next update." ]
  # The others name their messages in the same way.
  grep -q 'The network profile $name was refused: it is not taken.' "$lib/network-profiles"
  for m in "Factory reset: this takes a few minutes. Do not turn the device off." "Factory reset done: the device restarts." \
    "The factory reset failed this time: the next start tries again." \
    "The factory reset gave up: see factory-reset.log on the IRONFLOCKOS partition."; do
    grep -qF "on_screen \"$m\"" "$lib/factory-reset"
  done
  grep -q '^ExecStartPost=-/usr/lib/ironflockos/screen-message "Secure Boot is on: the NVIDIA GPU cannot be used.' \
    "$repo/profiles/nvidia/overlay/usr/lib/systemd/system/ironflockos-nvidia-secure-boot.service"
  # Plymouth quits after enroll: its message is the one that stays.
  grep -qx 'After=ironflockos-enroll.service' "$units/plymouth-quit.service.d/ironflockos.conf"
}

# --- no black between the firmware's picture and the splash (WP-8.7) --------

@test "GRUB draws the splash's colour, and its picture from splash.env and splash-screen.png, in graphics mode kept for the kernel" {
  . "$repo/build/lib.sh"
  for t in amd64-efi arm64-efi; do
    cfg=$(load_conf "$repo/targets/$t/target.conf" && render "$repo/targets/$t/grub/grub.cfg" | grep -v '^ *#')
    terminal=$(load_conf "$repo/targets/$t/target.conf" && echo "$GRUB_TERMINAL")
    block=$(echo "$cfg" | sed -n '/^if \[ "${splash}" = yes \]; then$/,/^else$/p')
    [[ "$block" == *"load_env --file \${prefix}/splash.env --skip-sig IRONFLOCKOS_SPLASH_BACKGROUND IRONFLOCKOS_SPLASH_MODE"* ]]
    [[ "$block" == *"if loadfont (memdisk)/fonts/unicode.pf2; then"* ]]
    [[ "$block" == *"if terminal_output gfxterm $terminal; then"* ]]
    [[ "$block" == *'background_color "${splash_background}"'* ]]
    # GRUB's script has no "!": every condition is a plain one.
    ! echo "$cfg" | grep -qE '^\s*(el)?if !'
    [[ "$block" == *'background_image -m normal ${prefix}/splash-screen.png'* ]]
    [[ "$block" == *'set gfxmode="${IRONFLOCKOS_SPLASH_MODE},auto"'* ]]
    [[ "$block" == *"set gfxpayload=keep"* ]]
    # Without the splash none of it: the console terminal, as before.
    [ "$(echo "$cfg" | grep -c 'gfxpayload\|terminal_output gfxterm\|background_')" -eq 4 ]
  done
  m=$repo/build/mkimage.sh
  grep -qF 'grub-editenv "$esp_dir/EFI/BOOT/splash.env" set "IRONFLOCKOS_SPLASH_BACKGROUND=#000000"' "$m"
  grep -qF '"$esp_dir/EFI/BOOT/grubenv" "$esp_dir/EFI/BOOT/splash.env" ::/EFI/BOOT/' "$m"
}

@test "consoles: the terminals get the console back only after a start with the console kept off the screen" {
  printf 'root=x quiet splash\n' >"$tmp/cmdline"
  mkdir -p "$tmp/dev"
  echo fb >"$tmp/dev/fb0"
  IRONFLOCKOS_PROC_CMDLINE=$tmp/cmdline IRONFLOCKOS_DEV=$tmp/dev run sh "$lib/consoles" fb0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # With fbcon=map:9 it asks the kernel; a file that is no framebuffer
  # refuses, which it says and does not fail on.
  printf 'root=x quiet splash fbcon=map:9\n' >"$tmp/cmdline"
  IRONFLOCKOS_PROC_CMDLINE=$tmp/cmdline IRONFLOCKOS_DEV=$tmp/dev run sh "$lib/consoles" fb0
  [ "$status" -eq 0 ]
  [[ "$output" == *"the virtual terminals have no console on $tmp/dev/fb0"* ]]
  grep -qx 'ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb\[0-9\]\*", RUN+="/usr/lib/ironflockos/consoles %k"' \
    "$repo/overlay/usr/lib/udev/rules.d/71-ironflockos-consoles.rules"
}

# framebuffer W H STRIDE: a 32-bit framebuffer in $tmp/fb with its sysfs
# files: the background #204060, a 4x2 block of #f08010 in the middle.
framebuffer() {
  local w=$1 h=$2 stride=$3 x y
  mkdir -p "$tmp/sys"
  echo "$w,$h" >"$tmp/sys/virtual_size"
  echo 32 >"$tmp/sys/bits_per_pixel"
  echo "$stride" >"$tmp/sys/stride"
  : >"$tmp/fb"
  for ((y = 0; y < h; y++)); do
    for ((x = 0; x < w; x++)); do
      if [ "$x" -ge 2 ] && [ "$x" -lt 6 ] && [ "$y" -ge 1 ] && [ "$y" -lt 3 ]; then
        printf '\x10\x80\xf0\x00' >>"$tmp/fb"
      else
        printf '\x60\x40\x20\x00' >>"$tmp/fb"
      fi
    done
    if [ "$stride" -gt $((4 * w)) ]; then head -c $((stride - 4 * w)) /dev/zero >>"$tmp/fb"; fi
  done
}

capture() {
  PATH="$tmp/bin:$PATH" IRONFLOCKOS_SCREEN=$tmp/screen IRONFLOCKOS_EFI_BOOT=$tmp/esp/EFI/BOOT IRONFLOCKOS_THEME=$tmp/theme \
    IRONFLOCKOS_RUN=$tmp/run IRONFLOCKOS_SPLASH_BIND=no IRONFLOCKOS_PROC_CMDLINE=$tmp/cmdline IRONFLOCKOS_SYS_FB=$tmp/sys \
    IRONFLOCKOS_FB=$tmp/fb IRONFLOCKOS_SYS_TTY_ACTIVE=$tmp/active IRONFLOCKOS_TTY1_MODE=${mode:-graphics} \
    run bash "$lib/splash" capture
}

@test "capture: with animation=none the whole screen becomes GRUB's picture, at its size; a new splash drops it" {
  png "$tmp/screen/splash.png" 64 48
  printf 'background=#204060\nanimation=none\n' >"$tmp/screen/splash.conf"
  splash
  [ "$status" -eq 0 ]
  printf 'root=x quiet splash fbcon=map:9\n' >"$tmp/cmdline"
  echo tty1 >"$tmp/active"
  framebuffer 8 4 40
  # The boot that took the files started without the archive.
  capture
  [[ "$output" == *"the splash changed during this boot: the screen is taken after the next one"* ]]
  # The next boot starts with it.
  rm "$tmp/run/splash-booted"
  splash
  capture
  [ "$status" -eq 0 ]
  [[ "$output" == *"took the screen (8x4): GRUB draws the splash from the next boot on"* ]]
  grep -qx 'IRONFLOCKOS_SPLASH_MODE=8x4' "$tmp/esp/EFI/BOOT/splash.env"
  # A PNG the image itself would take, of the framebuffer's pixels.
  splash check-png "$tmp/esp/EFI/BOOT/splash-screen.png"
  [ "$status" -eq 0 ]
  if command -v python3 >/dev/null; then
    run python3 -I -c '
import sys, zlib
d = open(sys.argv[1], "rb").read()
pos, idat = 8, b""
while pos < len(d):
    n = int.from_bytes(d[pos:pos + 4], "big"); kind = d[pos + 4:pos + 8]; body = d[pos + 8:pos + 8 + n]
    assert zlib.crc32(kind + body) == int.from_bytes(d[pos + 8 + n:pos + 12 + n], "big"), kind
    if kind == b"IDAT": idat += body
    pos += 12 + n
rows = zlib.decompress(idat)
print(" ".join(rows[y * 25 + 1:(y + 1) * 25].hex() for y in range(4)))' "$tmp/esp/EFI/BOOT/splash-screen.png"
    [ "$status" -eq 0 ]
    bg=204060 fg=f08010
    [ "$output" = "$bg$bg$bg$bg$bg$bg$bg$bg $bg$bg$fg$fg$fg$fg$bg$bg $bg$bg$fg$fg$fg$fg$bg$bg $bg$bg$bg$bg$bg$bg$bg$bg" ]
  fi
  # The same again: nothing to do.
  capture
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # A new picture drops GRUB's; the boot after it takes the screen anew.
  png "$tmp/screen/splash.png" 32 32
  splash
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/esp/EFI/BOOT/splash-screen.png" ]
  ! grep -q IRONFLOCKOS_SPLASH_MODE "$tmp/esp/EFI/BOOT/splash.env"
  capture
  [[ "$output" == *"the splash changed during this boot: the screen is taken after the next one"* ]]
  [ ! -e "$tmp/esp/EFI/BOOT/splash-screen.png" ]
}

@test "capture: nothing with fade, without the splash, with another terminal in front or not in graphics mode, or not the splash's colour" {
  png "$tmp/screen/splash.png" 64 48
  printf 'background=#204060\n' >"$tmp/screen/splash.conf"
  splash
  printf 'root=x quiet splash fbcon=map:9\n' >"$tmp/cmdline"
  echo tty1 >"$tmp/active"
  framebuffer 8 4 32
  capture
  [ "$status" -eq 0 ]
  [ ! -e "$tmp/esp/EFI/BOOT/splash-screen.png" ]
  printf 'background=#204060\nanimation=none\n' >"$tmp/screen/splash.conf"
  splash
  rm "$tmp/run/splash-booted"
  splash
  printf 'root=x plymouth.enable=0\n' >"$tmp/cmdline"
  capture
  [ -z "$output" ]
  printf 'root=x quiet splash fbcon=map:9\n' >"$tmp/cmdline"
  echo tty2 >"$tmp/active"
  capture
  [[ "$output" == *"the first terminal is not the splash's: the screen is not taken"* ]]
  echo tty1 >"$tmp/active"
  mode=text capture
  [[ "$output" == *"the first terminal is not the splash's: the screen is not taken"* ]]
  printf 'background=#000000\nanimation=none\n' >"$tmp/screen/splash.conf"
  splash
  rm "$tmp/run/splash-booted"
  splash
  capture
  [[ "$output" == *"the screen does not show the splash's background: it is not taken"* ]]
  [ ! -e "$tmp/esp/EFI/BOOT/splash-screen.png" ]
  grep -qx 'ConditionKernelCommandLine=splash' "$units/ironflockos-splash-capture.service"
  grep -qx 'After=plymouth-quit.service ironflockos-splash.service' "$units/ironflockos-splash-capture.service"
}
