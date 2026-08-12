#############################################################################
# Does this Innovus have a target-slack knob, and what is it called?
#
#     innovus -nowin -files scripts/probe_optmode.tcl
#
# Author: Elliot Staresinic
#
# A minute, no design loaded, nothing routed. It answers the one question that
# would otherwise cost a full synthesis to ask, because the guard in
# innovus.tcl that refuses a run with no margin fires AFTER Genus has finished.
# Four runs at 13 to 17 minutes each is an hour; finding out first is cheap.
#
# WHY A FILE AND NOT A PASTED COMMAND. Pasting into the VNC xterm drops
# characters, and it has already eaten a "--from" once. Same reason sweep.sh
# lives in the repo.
#
# WHAT IT IS CHECKING. setOptMode raises the slack at which the optimiser
# STOPS, without touching the constraint it is judged by. That distinction is
# the whole reason the margin is not being added to clock uncertainty instead:
# there is one constraint mode here, it is active for the final analysis too,
# and margin added there moves the ruler along with the target. The long
# version of the argument is in scripts/innovus.tcl.
#
# AN OPTION INNOVUS DOES NOT KNOW CAN WARN AND RETURN SUCCESS. That is exactly
# how `timeDesign -postRoute -si` got recorded as a step that ran: it printed
# IMPOPT-7017, did nothing, and exited zero. So every option here is set and
# then READ BACK, and only a value that comes back is treated as supported.
#############################################################################

set PROBE 0.06

puts ""
puts "### ####################################################"
puts "### setOptMode target-slack probe, asking for $PROBE ns"
puts "### ####################################################"

set SUPPORTED {}
foreach opt {setupTargetSlack postRouteSetupTargetSlack holdTargetSlack} {
    if {[catch {setOptMode -$opt $PROBE} msg]} {
        puts [format "%-28s NOT ACCEPTED   %s" $opt $msg]
        continue
    }
    if {[catch {getOptMode -$opt} got]} {
        puts [format "%-28s set, UNREADABLE  %s" $opt $got]
        continue
    }
    puts [format "%-28s -> %s" $opt $got]
    lappend SUPPORTED $opt
}

puts ""
if {[lsearch $SUPPORTED setupTargetSlack] >= 0} {
    puts "### setupTargetSlack IS SUPPORTED. The flow will work as written:"
    puts "###     bash sweep.sh confirm 4.1 0.06"
} else {
    puts "### setupTargetSlack IS NOT SUPPORTED under this Innovus."
    puts "### DO NOT start the sweep. innovus.tcl will refuse every run, but"
    puts "### only after Genus has spent its minutes. The margin needs another"
    puts "### knob; report this output before changing anything."
}
puts "### supported here: $SUPPORTED"
puts ""

exit
