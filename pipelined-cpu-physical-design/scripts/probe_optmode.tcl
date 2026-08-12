#############################################################################
# Which target-slack option does this Innovus actually have?
#
#     cd $PNR_ROOT
#     innovus -nowin -files scripts/probe_optmode.tcl
#
# Author: Elliot Staresinic
#
# A minute, no design, no route. It exists because the guard in innovus.tcl
# that refuses a run with no margin fires AFTER Genus, so a wrong option name
# costs a full synthesis per run to discover, and a sweep is four of them.
#
# WHY A FILE AND NOT A PASTED COMMAND. Pasting into the VNC xterm drops
# characters and breaks long lines at the wrap. The first attempt at this probe
# was a 100-character one-liner and the xterm split it in two, so `-files`
# arrived with no argument and bash then tried to execute the .tcl directly.
# Keep the invocation under about 50 characters. Same reason sweep.sh exists.
#
# READ THE ERROR CODE, NOT THE PASS/FAIL. That is the whole lesson of the first
# run of this probe, 2026-08-12, which reported NOT SUPPORTED for an option
# that was fine. setOptMode fails two completely different ways here and only
# one of them is fatal:
#
#   IMPTCM-48   "... is not a legal option for command setOptMode"
#               The option does not exist. Fatal. Argument parsing rejected it.
#
#   IMPOPT-581  "Design not in memory."
#               The option PARSED and the command got as far as needing a
#               design, which this probe deliberately does not load. NOT fatal:
#               in innovus.tcl the call sits after init_design/restoreDesign,
#               so a design is always in memory by then.
#
# Innovus writes both of those to stdout itself rather than into the Tcl error
# message, so `catch` comes back with an empty string and this script CANNOT
# classify them for you. It prints what it can and tells you what to look for.
# Do not let it hand you a binary verdict it has not earned.
#
# WHAT WAS FOUND on 23.12-s091_1: `setOptMode -help` lists only Common UI
# spellings and the real one is -opt_setup_target_slack. There is no post-route
# variant; -postRouteSetupTargetSlack is IMPTCM-48, and the nearest entry,
# -opt_post_route_setup_recovery, is area recovery and a different knob.
#############################################################################

set PROBE 0.06

puts ""
puts "### ####################################################"
puts "### setOptMode target-slack probe, asking for $PROBE ns"
puts "###"
puts "### Innovus prints its own error ABOVE each result line."
puts "###   IMPTCM-48  = no such option        -> fatal, wrong name"
puts "###   IMPOPT-581 = option parsed, wants a design -> FINE, the flow has one"
puts "### ####################################################"
puts ""

foreach opt {opt_setup_target_slack setupTargetSlack
             opt_hold_target_slack postRouteSetupTargetSlack} {
    puts "--- trying -$opt"
    if {[catch {setOptMode -$opt $PROBE} msg]} {
        set detail $msg
        if {$detail eq ""} { set detail "(Innovus printed it above; read the code)" }
        puts [format "%-28s RAISED   %s" $opt $detail]
        # errorCode sometimes carries the tag when the message does not. Free to
        # print, and if it ever does this probe becomes definitive.
        if {[info exists ::errorCode] && $::errorCode ne "NONE"} {
            puts [format "%-28s code     %s" $opt $::errorCode]
        }
    } else {
        if {[catch {getOptMode -$opt} got]} { set got "(set, unreadable)" }
        puts [format "%-28s ACCEPTED, reads back %s" $opt $got]
    }
    puts ""
}

puts "### ####################################################"
puts "### HOW TO READ THIS"
puts "###"
puts "### -opt_setup_target_slack is the name innovus.tcl tries first."
puts "### If its error above is IMPOPT-581, that is the expected result for a"
puts "### probe with no design and the sweep is good to go:"
puts "###"
puts "###     bash sweep.sh confirm 4.1 0.06"
puts "###"
puts "### If its error is IMPTCM-48, the name is wrong on this build. Do NOT"
puts "### start the sweep; report the output and the usage list Innovus dumps."
puts "### ####################################################"
puts ""

exit
