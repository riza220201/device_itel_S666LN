#!/vendor/bin/sh

########################################################
### init.insmod.cfg format:                          ###
### -----------------------------------------------  ###
### [insmod|setprop|enable/moprobe] [path|prop name] ###
### ...                                              ###
########################################################

if [ $# -eq 1 ]; then
  cfg_file=$1
else
  exit 1
fi

if [ -f $cfg_file ]; then
  while IFS="|" read -r action arg
  do
    case $action in
      "insmod") insmod $arg ;;
      "setprop") setprop $arg 1 ;;
      "enable") echo 1 > $arg ;;
      "modprobe")
        # One module per modprobe call instead of a single batched -a.
        #
        # Batched, a failure is anonymous: modprobe returns 0, prints nothing a
        # kernel log would keep, and init happily sets vendor.all.modules.ready
        # regardless. Build 20 loaded 0 of 177 vendor_dlkm modules that way --
        # including mali_kbase, so eglInitialize failed, surfaceflinger aborted
        # with "no suitable EGLConfig found" and the device sat on the boot
        # animation. The identical command run by hand after boot loaded 153.
        #
        # Per-module calls cost ~177 execs and change nothing else: modprobe
        # still resolves each module's own dependencies from modules.dep. What
        # they buy is a name attached to every failure, in order, on kmsg --
        # the service carries stdio_to_kmsg so init does the writing and the
        # script needs no policy of its own.
        case ${arg} in
          "-b *" | "-b") mp_opts="-b" ;;
          "*" | "")      mp_opts="" ;;
        esac

        # BUILTINS ONLY. A vendor process's PATH is /vendor/bin, which holds
        # sh, awk, toolbox, modprobe and little else -- there is no cat, no
        # wc, no grep and no tr. The stock script's
        #
        #     arg="$(cat /vendor/lib/modules/modules.load)"
        #
        # therefore expanded to nothing at boot, modprobe was handed an empty
        # list, and it exited 0 having loaded not one module. That is the whole
        # reason vendor_dlkm loaded 0 of 177: not ordering, not dependencies,
        # not a probe race. The kernel log said so the moment stdio_to_kmsg and
        # the sepolicy rule let it speak:
        #
        #     init.insmod.sh[86]: cat: inaccessible or not found
        #     init.insmod: pass 1: 0 failed of 0
        #
        # It looked like a timing problem for a day because running the same
        # script from `adb shell` works -- that PATH includes /system/bin, so
        # cat resolves. mksh gives us ${x%.ko}, ${x//-/_}, read and case, so
        # nothing external is needed at all.
        #
        # Multi-pass is kept regardless: a module whose dependency has not
        # finished probing fails and succeeds on a later pass. Stop when a pass
        # loads nothing new, so a genuinely broken module costs one extra pass
        # rather than a boot loop.
        mp_prev=-1
        mp_pass=0
        while [ ${mp_pass} -lt 6 ]; do
          mp_pass=$((mp_pass + 1))

          # Resident set and count, straight from /proc/modules.
          mp_res=" "
          mp_now=0
          while read -r mp_l mp_junk; do
            mp_res="${mp_res}${mp_l} "
            mp_now=$((mp_now + 1))
          done < /proc/modules

          mp_n=0
          mp_fail=0
          while read -r mp_mod mp_junk; do
            [ -z "${mp_mod}" ] && continue
            mp_n=$((mp_n + 1))
            # /proc/modules always spells names with '_', whatever the file uses.
            mp_name=${mp_mod%.ko}
            mp_name=${mp_name//-/_}
            case "${mp_res}" in
              *" ${mp_name} "*) continue ;;
            esac
            # stdin from /dev/null: modprobe must not eat the list this loop
            # is reading.
            if ! modprobe ${mp_opts} -d /vendor/lib/modules "${mp_mod}" \
                 < /dev/null 2>/dev/null; then
              mp_fail=$((mp_fail + 1))
              echo "init.insmod: pass ${mp_pass} FAIL #${mp_n} ${mp_mod}"
            fi
          done < /vendor/lib/modules/modules.load

          echo "init.insmod: pass ${mp_pass}: ${mp_fail} failed of ${mp_n}, ${mp_now} resident at pass start"
          [ "${mp_now}" = "${mp_prev}" ] && break
          mp_prev=${mp_now}
        done
        echo "init.insmod: settled after ${mp_pass} pass(es)"
        ;;
    esac
  done < $cfg_file
fi

