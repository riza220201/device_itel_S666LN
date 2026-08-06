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

        # Multi-pass, because this list is raced against driver probing.
        #
        # At ~2.4 s the subsystems these modules bind to (SSPM, GPUEB, SCP) are
        # not up yet, so a module fails, and every module that needs a symbol
        # from it fails after it -- fpsgo (#109) died on notify_xgf_ko_ready,
        # exported by mtk_fpsgo (#108), which had failed moments earlier. One
        # pass loaded 0 of 177 at boot. The identical pass at 968 s uptime, on
        # the same device in the same state, loaded 174. Nothing about the
        # modules, the order, modules.dep or the loader is wrong; they are
        # simply asked too early.
        #
        # Rather than guess which subsystem is slow and move the trigger to
        # match (the trigger is MediaTek's own, and a shipping MT6789 device
        # uses this rc verbatim), just go round again: a module whose
        # dependency has since finished probing loads on the next pass. Stop
        # when a pass loads nothing new, so a genuinely broken module costs one
        # extra pass and not a boot loop.
        mp_prev=-1
        mp_pass=0
        while [ ${mp_pass} -lt 6 ]; do
          mp_pass=$((mp_pass + 1))
          mp_n=0; mp_fail=0
          for mp_mod in $(cat /vendor/lib/modules/modules.load); do
            mp_n=$((mp_n + 1))
            # Already resident: modprobe reports EEXIST as a plain failure, so
            # without this every later pass would log 174 phantom failures.
            # /proc/modules spells names with '_' whatever the file uses.
            mp_name=$(echo "${mp_mod%.ko}" | tr '-' '_')
            grep -q "^${mp_name} " /proc/modules && continue
            if ! modprobe ${mp_opts} -d /vendor/lib/modules "${mp_mod}" 2>/dev/null; then
              mp_fail=$((mp_fail + 1))
              echo "init.insmod: pass ${mp_pass} FAIL #${mp_n} ${mp_mod}"
            fi
          done
          mp_now=$(wc -l < /proc/modules)
          echo "init.insmod: pass ${mp_pass}: ${mp_fail} failed of ${mp_n}, ${mp_now} modules resident"
          [ "${mp_now}" = "${mp_prev}" ] && break
          mp_prev=${mp_now}
        done
        echo "init.insmod: settled after ${mp_pass} pass(es), ${mp_prev} modules resident"
        ;;
    esac
  done < $cfg_file
fi

