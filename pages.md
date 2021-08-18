# User visible endpoints

## /home.html

The entry page.  Lists the available channels and some general information.
Probably should contain some per channel blurb, obtained from a file that
lives in the channel's static or template directory.

Lists the years / months of which there are logs available.

More or less functional now.

## /search.html

The general search page.  Contains all of the possible filter possibilities.
Search results to always be shown in ascending chronological order.

Completely functional backend-wise.

User-interface features:
- show N lines around given line (/channel/around.html endpoint)

Returns JSON if the extension is .json.

## /channel/index.html

The index page of a channel.  Lists the years / months / days on which logs
are available, with only the ones actually having messages being clickable.
Or have them all clickable, but use some colour indication as to the number
of messages available for that day (compared to the maximum).

More or less functional now, except for the colour indication of "traffic".
But should be easily addable in the backend.

## /channel/YYYY-MM-DD

The raw log of the given channel and date, in IRC::Log::Colabti format.

## /channel/YYYY-MM-DD.html

The conceptual page for a given date.  This is the place where all historical
references should go to.

Completely functional backend-wise.

Links to:
- search.html
- live.html
- index.html
- home.html

User interface features:
- provide link target for deep-linking
- add line(s) to collection of targets
- link to /channel/targets.html if there are targets
- link to oldest / newest / today / random date
- link to next / previous date / month / year

## /channel/YYYY

Redirect to the first date of the given year of which there is a log.

## /channel/YYYY-MM

Redirect to the first date of the given year and month of which there is a log.

## /channel/prev/YYYY-MM-DD

Redirect to the first date before the given date of which there is a log.

## /channel/this/YYYY-MM-DD

Redirect to the given date if there is a log for that date.  If not, try to
look if there's a later log and redirect to that.  If there is none, redirect
to the first date of which there is a log before the given date.

## /channel/search.html

Entry point for searching on a channel.  Uses the same template as /search.html,
just with the channel value obtained from the route, rather then from
parameters.

## /channel/live.html

A live version of the messages on the channel.  On entry, shows the last N
messages, and should (perhaps automatically, perhaps after the user does a
scroll-up action) add any new messages below.

At the top, it should be possible to obtain messages that were done before.
Functionality is now available in temporary /channel/scroll-up.html and
/channel/scroll-down.html, although writing this down now, I think I've
actually named them the wrong way around :-)

If there are no new messages to obtain, the scroll-up/down endpoints will
return a 204 status (no change).

Returns JSON if the extension is .json.

## /channel/gist.html

A page for displaying the messages given by the targets.  The intent is to
be able to provide a link to the actual significant parts of a discussion,
without having the distraction of any other discussions that were going on
at the time.

Possibly, this should have an index page of its own, or be part of the
index page.  In any case, this feels to be a future additional functionality.

## /channel/today

Redirects to the /channel/YYYY-MM-DD.html closest to the current date.

## /channel/first

Redirects to the first (oldest) /channel/YYYY-MM-DD.html closest to the
current date.

## /channel/last

Redirects to the last (newest) /channel/YYYY-MM-DD.html.

## /channel/random

Redirects to a randomly selected /channel/YYYY-MM-DD.html.

# non-user visible endpoints

## /channel/around.html

Endpoint returning the HTML (or JSON if the extension is .json) for the given
number of lines around a given target.  Intended to be used from /search.html.

Backend functional.

## /channel/targets.html

Endpoint returning the HTML (or JSON if the extension is .json) for the given
targets.

Backend functional.

## /channel/scroll-down.html

Endpoint returning the HTML (or JSON if the extension is .json) for the given
target and number of entries for any *new* messages.

Due to the nature of rendering messages (e.g. with a separate row for the nick),
it is not a matter of just adding lines anymore.  So the template knows from
which target it should look, and only if there are now more than the original
number of lines from that target, are there any new lines to be shown.

To be used in /channel/live.html.  Returns 204 if there's nothing to do.

## /channel/scroll-up.html

Endpoint returning the HTML (or JSON if the extension is .json) for any messages
*until* the given target.

Due to the nature of rendering messages (e.g. with a separate row for the nick),
it is not a matter of just adding lines anymore.  So the template knows from
which target it should look, and only if there are actually lines before the
target, are there any lines returned.

To be used in /channel/live.html.  Returns 204 if there's nothing to do.
