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
        mp_n=0; mp_ok=0; mp_fail=0
        for mp_mod in $(cat /vendor/lib/modules/modules.load); do
          mp_n=$((mp_n + 1))
          if modprobe ${mp_opts} -d /vendor/lib/modules "${mp_mod}" 2>&1; then
            mp_ok=$((mp_ok + 1))
          else
            mp_fail=$((mp_fail + 1))
            echo "init.insmod: FAIL #${mp_n} ${mp_mod}"
          fi
        done
        echo "init.insmod: ${mp_ok} loaded, ${mp_fail} failed, of ${mp_n}"
        ;;
    esac
  done < $cfg_file
fi

