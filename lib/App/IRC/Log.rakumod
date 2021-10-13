use v6.*;

use Array::Sorted::Util:ver<0.0.7>:auth<zef:lizmat>;
use Cro::HTTP::Router:ver<0.8.6>;
use Cro::WebApp::Template:ver<0.8.6>;
use Cro::WebApp::Template::Repository:ver<0.8.6>;
use IRC::Channel::Log:ver<0.0.36>:auth<zef:lizmat>;
use JSON::Fast:ver<0.16>;
use RandomColor;

# Array for humanizing dates
my constant @human-months = <?
  January February March April May June July
  August September October November December
>;

# Turn a YYYY-MM-DD date into a human readable date
sub human-date(str $date, str $del = ' ', :$short) {
    if $date {
        my $chars := $short ?? 3 !! *;
        $date.substr(8,2).Int
          ~ $del
          ~ @human-months[$date.substr(5,2)].substr(0,$chars)
          ~ $del
          ~ $date.substr(0,4)
    }
}

# Turn a YYYY-MM-DD date into a human readable month
sub human-month(str $date, str $del = ' ', :$short) {
    if $date {
        my $chars := $short ?? 3 !! *;
        @human-months[$date.substr(5,2)].substr(0,$chars)
          ~ $del
          ~ $date.substr(0,4)
    }
}

# Month pulldown
my constant @template-months =
   1 => "Jan",
   2 => "Feb",
   3 => "Mar",
   4 => "Apr",
   5 => "May",
   6 => "Jun",
   7 => "Jul",
   8 => "Aug",
   9 => "Sep",
  10 => "Oct",
  11 => "Nov",
  12 => "Dec",
;

# Default color generator
sub generator($) {
    RandomColor.new(:luminosity<bright>).list.head
}

sub add-search-pulldown-values(%params --> Nil) {
    %params<entries-pp-options> := <25 50 100 250 500>;
    %params<message-options> := (""           => "all messages",
                                 conversation => "text only",
                                 control      => "control only",
                                );
    %params<type-options> := (words       => "as word(s)",
                              contains    => "containing",
                              starts-with => "starting with",
                              matches     => "as regex",
                             );
}

# Create result given template, parameters and json flag
sub create-result($crot, %params, $json) {
    $json
      ?? to-json(%params,:!pretty)
      !! render-template $crot, %params
}

#-------------------------------------------------------------------------------
# App::IRC::Log class
#

class App::IRC::Log:ver<0.0.30>:auth<zef:lizmat> {
    has         $.log-class     is required;
    has IO()    $.log-dir       is required;  # IRC-logs
    has IO()    $.static-dir    is required;  # static files, e.g. favicon.ico
    has IO()    $.template-dir  is required;  # templates
    has IO()    $.rendered-dir  is required;  # renderings of template
    has IO()    $.state-dir     is required;  # saving state
    has IO()    $.zip-dir;                    # saving zipped renderings
    has         &.colorize-nick is required;  # colorize a nick in HTML
    has         &.htmlize       is required;  # make HTML of message of entry
    has Instant $.liftoff is built(:bind) = $*INIT-INSTANT;
    has str     @.channels = self.default-channels;  # channels to provide
    has         @.live-plugins;                      # any plugins for live
    has         @.day-plugins;                       # any plugins for day
    has         %.descriptions;                      # channel descriptions
    has         %!clogs;       # hash of IRC::Channel::Log objects

    my constant $nick-colors-json = 'nicks.json';

    # Determine default channels from a logdir
    multi method default-channels(App::IRC::Log:D:) {
        self.default-channels($!log-dir)
    }
    multi method default-channels(App::IRC::Log: IO:D $log-dir) {
        $log-dir.dir.map({
          .basename
          if .d
          && !.basename.starts-with('.')
          && .dir(:test(/ ^ \d\d\d\d $ /)).elems
        }).sort
    }

    # Start loading the logs asynchronously.  No need to be thread-safe
    # here as here will only be the thread creating the object.
    submethod TWEAK(:$batch = 16, :$degree = Kernel.cpu-cores --> Nil) {
        my @problems;
        for
          :$!log-dir, :$!static-dir, :$!template-dir,
          :$!rendered-dir, :$!state-dir
        -> (:key($name), :value($io)) {
            @problems.push("'$name' does not point to a valid directory: $io")
              unless $io.e && $io.d;
        }
        if $!zip-dir -> $io {
            @problems.push("'zip-dir' does not point to a valid directory: $io")
              unless $io.e && $io.d;
        }
        if @problems {
            die ("Found problems in directory specification:",
              |@problems).join: "\n  ";
        }

        %!clogs{$_} := start {  # start by storing the Promise
            my $clog := IRC::Channel::Log.new:
              logdir    => $!log-dir.add($_),
              class     => $!log-class,
              generator => &generator,
              state     => $!state-dir.add($_),
              name      => $_,
              batch     => $batch,
              degree    => $degree,
            ;

            # Monitor active channels for changes
            if $clog.active {
                my str $last-date = $clog.dates.tail;
                my str $channel   = $clog.name;
                my $home  := $!rendered-dir.add('home.html');
                my $index := $!rendered-dir.add($channel).add('index.html');
                $clog.watch-and-update: post-process => {
                    if .date ne $last-date {
                        .unlink for $index, $home;
                        $last-date = .date.Str;
                    }
                }
            }

            $clog  # the result of the Promise
        } for @!channels;
    }

    # Perform all actions associated with shutting down.
    # Expected to be run *after* the application has stopped.
    method shutdown(App::IRC::Log:D: --> Nil) {
        self.clog($_).shutdown for @!channels;
    }

#-------------------------------------------------------------------------------
# Methods related to rendering

    # Return IRC::Channel::Log object for given channel
    method clog(App::IRC::Log:D: str $channel --> IRC::Channel::Log:D) {

        # Even though this could be called from several threads
        # simultaneously, the key should always exist, so there
        # is no danger of messing up the hash.  The only thing
        # that can happen, is binding the result of the Promise
        # more than once to the hash.
        given %!clogs{$channel} {
            if $_ ~~ Promise {
                %!clogs{$channel} := .result  # not ready yet
            }
            else {
                $_ // Nil                     # ready, so go!
            }
        }
    }

    # Set up entries for use in template
    method !ready-entries-for-template(\entries, $channel, %colors, :$short) {
        my str $last-date = "";
        my str $last-hhmm = "";
        my str $last-nick = "";
        my int $last-type = -1;
        entries.map: {
            my str $date = .date.Str;
            my str $hhmm = .hh-mm // "";
            my str $nick = .nick;
            my int $type = .control.Int;
            my %hash =
              channel         => $channel,
              date            => $date,
              hour            => .hour,
              message         => &!htmlize($_, %colors),
              nick            => $nick,
              minute          => .minute,
              ordinal         => .ordinal,
              relative-target => .target.substr(11),
              sender          => &!colorize-nick($nick, %colors),
              target          => .target
            ;
            %hash<same-nick>    := True if $nick && $nick eq $last-nick;
            %hash<control>      := True if .control;
            if .conversation {
                %hash<conversation>   := True;
                %hash<self-reference> := True unless .sender;
            }
            %hash<hh-mm> := $hhmm
              unless $hhmm eq $last-hhmm && $type == $last-type;
            %hash<human-date> := human-date($date, "\xa0", :$short)
              unless $date eq $last-date;

            $last-date = $date;
            $last-hhmm = $hhmm;
            $last-nick = $type ?? "" !! $nick;
            $last-type = $type;
            %hash
        }
    }

    # Return IO object for given channel and day
    method !day($channel, $file --> IO:D) {
        my $date := $file.chop(5);
        my $Date := $date.Date;
        my $year := $Date.year;
        my $log  := $!log-dir.add($channel).add($year).add($date);
        my $html := $!rendered-dir.add($channel).add($year).add("$date.html");
        my $crot := $!template-dir.add('day.crotmp');

        # Need to (re-)render
        if !$html.e                           # file does not exist
          || $html.modified < $log.modified   # log was updated
                            | $!liftoff       # file is too old
                            | $crot.modified  # or template changed
        {

            # Set up entries for use in template
            my $clog   := self.clog($channel);
            my @dates  := $clog.dates;
            my %colors := $clog.colors;
            my @entries = self!ready-entries-for-template(
              $clog.log($date).entries, $channel, %colors
            );

            # Run all the plugins
            for @!day-plugins -> &plugin {
                &plugin.returns ~~ Nil
                  ?? plugin(@entries)
                  !! (@entries = plugin(@entries))
            }

            # Set up parameters
            my %params =
              :$channel,
              :@!channels,
              :$date,
              :date-human("$Date.day() @human-months[$Date.month] $Date.year()"),
              :next-date($Date.later(:1day)),
              :next-month($date.substr(0,7).succ),
              :next-year($date.substr(0,4).succ),
              :prev-date($Date.earlier(:1day)),
              :prev-month($clog.is-first-date-of-month($date)
                ?? "this/$Date.earlier(:1month).first-date-in-month()"
                !! $date.substr(0,7)
              ),
              :prev-year($clog.is-first-date-of-year($date)
                ?? 'this/' ~ Date.new($Date.year - 1, 1, 1)
                !! $date.substr(0,4)
              ),
              :start-date($date),
              :end-date($date),
              :first-date(@dates.head),
              :last-date(@dates.tail),
              :@entries
            ;

            # Add topic related parameters if any
            with $clog.initial-topic($date) -> $topic {
                %params<initial-topic-text> :=
                  &!htmlize($topic, %colors);
                %params<initial-topic-nick> :=
                  &!colorize-nick($topic.nick, %colors);
                %params<initial-topic-date> :=
                  $topic.date.Str;
                %params<initial-topic-human-date> :=
                  human-date($topic.date.Str);
                %params<initial-topic-relative-target> :=
                  $topic.target.substr(11);
                %params<initial-topic-target> :=
                  $topic.target;
            }
            add-search-pulldown-values(%params);

            # Render it!
            self!render: $!rendered-dir, $html, $crot, %params;
        }
        $html
    }

    # Return an IO object for /home.html
    method !home(--> IO:D) {
        my $html := $!rendered-dir.add('home.html');
        my $crot := $!template-dir.add('home.crotmp');

        if !$html.e                           # file does not exist
          || $html.modified < $!liftoff       # file is too old
                            | $crot.modified  # or template changed
        {
            my @channels = @!channels.map: -> $channel {
                my $clog  := self.clog($channel);
                my @dates := $clog.dates;
                my %months = @dates.categorize: *.substr(0,7);
                my %years  = %months.categorize: *.key.substr(0,4);
                my @years  = %years.sort(*.key).map: {
                    Map.new((
                      channel => $channel,
                      year    => .key,
                      months  => .value.sort(*.key).map: {
                         Map.new((
                            channel     => $channel,
                            month       => .key,
                            human-month =>
                              @human-months[.key.substr(5,2)].substr(0,3),
                         ))
                      },
                    ))
                }

                my $first-date := @dates.head;
                my $last-date  := @dates.tail;

                Map.new((
                  name             => $channel,
                  years            => @years,
                  start-date       => $last-date,
                  end-date         => $last-date,
                  first-date       => $first-date,
                  first-human-date => human-date($first-date),
                  last-date        => $last-date,
                  last-human-date  => human-date($last-date),
                ))
            }

            my %params =
              channels => @channels,
            ;
            add-search-pulldown-values(%params);
            self!render: $!rendered-dir, $html, $crot, %params;
        }
        $html
    }

    method !template-for(str $channel, str $name) {
        my str $filename = $name ~ '.crotmp';
        my $crot := $!template-dir.add($channel).add($filename);
        $crot.e
          ?? $crot
          !! $!template-dir.add: $filename
    }

    # Return an IO object for /channel/index.html
    method !index(str $channel --> IO:D) {
        my $html := $!rendered-dir.add($channel).add('index.html');
        my $crot := self!template-for($channel, 'index');

        if !$html.e                           # file does not exist
          || $html.modified < $!liftoff       # file is too old
                            | $crot.modified  # or template changed
        {
            my $clog  := self.clog($channel);
            my @dates := $clog.dates;
            my $first-date := @dates.head;
            my $last-date  := @dates.tail;

            my str $last-yyyy-mm;
            my int $days-in-month;
            my @days;
            my @months;
            my @years;

            sub finish-month(--> Nil) {
                if @days {
                    my int $days = $last-date.starts-with($last-yyyy-mm)
                      ?? $last-date.substr(8,2).Int
                      !! $days-in-month;

                    # fill up any holes
                    for ^$days -> int $i {
                        @days[$i] := Map.new( (day => $i + 1) )
                          without @days[$i];
                    }

                    @months.push: Map.new((
                      channel     => $channel,
                      month       => $last-yyyy-mm,
                      human-month => @human-months[$last-yyyy-mm.substr(5,2)],
                      dates       => @days.clone,
                    ));
                    @days = ();
                }
            }

            sub finish-year(--> Nil) {
                if @months {
                    @years[@years.elems] := Map.new((
                      channel => $channel,
                      year    => $last-yyyy-mm.substr(0,4),
                      months  => @months.clone,
                    ));
                    @months = ();
                }
            }

            for @dates -> $date {
                my str $yyyy-mm = $date.substr(0,7);
                my int $day     = $date.substr(8,2).Int;

                # new month
                if $yyyy-mm ne $last-yyyy-mm {
                    finish-month;
                    $days-in-month = $date.Date.days-in-month;

                    finish-year
                      if !$last-yyyy-mm.starts-with($date.substr(0,4));

                    $last-yyyy-mm = $yyyy-mm;
                }

                @days[$day - 1] := Map.new((
                  channel      => $channel,
                  date         => $date,
                  day          => $day,
                )) if $clog.log($date).nr-conversation-entries;
            }
            finish-month;
            finish-year;

            my %params =
              channel          => $channel,
              channels         => @!channels,
              description      => %!descriptions{$channel},
              years            => @years,
              start-date       => $last-date,
              end-date         => $last-date,
              first-date       => $first-date,
              first-human-date => human-date($first-date),
              last-date        => $last-date,
              last-human-date  => human-date($last-date),
            ;
            add-search-pulldown-values(%params);

            self!render: $!rendered-dir, $html, $crot, %params;
        }
        $html
    }

    # Convert a string to a regex that stringifies as the string
    sub string2regex(Str:D $string) {
        if $string.contains('{') {   # XXX naive security check
            Nil
        }
        else {
            my $regex = "/ $string /";
            $regex.EVAL but $regex   # XXX fix after RakuAST lands
        }
    }

    # Return content for around target helper
    method !around(
      :$channel!,
      :$target!,
      :$nr-entries,
      :$conversation,
      :$control,
      :$json,
    ) {
        my $crot := self!template-for($channel, 'around');
        get-template-repository.refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        my $clog := self.clog($channel);

        my %params;
        %params<channel>       := $channel;
        %params<around-target> := $target;
        %params<nr-entries>    := $nr-entries   if $nr-entries;
        %params<control>       := $control      if $control;
        %params<conversation>  := $conversation if $conversation;

        sub find-em() {
            if $clog.entries(|%params) -> @found {
                self!ready-entries-for-template(
                  @found, $channel, $clog.colors, :short
                )
            }
        }

        my $then    := now;
        my @entries  = find-em;
        my $elapsed := ((now - $then) * 1000).Int;

        .<is-target> := True
          given @entries[@entries.first: *.<target> eq $target, :k];

        %params =
          channel  => $channel,
          channels => @!channels,
          dates    => $clog.dates,
          target   => $target,
          elapsed  => $elapsed,
          entries  => @entries,
        ;

        create-result($crot, %params, $json)
    }

    # Return content for gist helper
    method !gist(
       $channel,
       $targets?,
      :$json,
    ) {
        my $crot := self!template-for($channel, 'gist');
        get-template-repository.refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        my $clog  := self.clog($channel);
        my @dates := $clog.dates;

        my str @targets = $targets.split(",");
        my %params;
        %params<channel> := $channel;
        %params<targets> := @targets;

        sub find-em() {
            if $clog.entries(|%params) -> @found {
                self!ready-entries-for-template(
                  @found, $channel, $clog.colors, :short
                )
            }
        }

        my $then    := now;
        my @entries  = find-em;
        my $elapsed := ((now - $then) * 1000).Int;

        %params =
          channel    => $channel,
          channels   => @!channels,
          first-date => @dates.head,
          last-date  => @dates.tail,
          targets    => @targets,
          elapsed    => $elapsed,
          entries    => @entries,
        ;

        if @entries {
            %params<start-date> := @entries.head<date>;
            %params<end-date>   := @entries.tail<date>;
        }
        add-search-pulldown-values(%params);
        create-result($crot, %params, $json)
    }

    # Return content for scroll-up entries
    method !scroll-up(
       $channel,
      :$target!,
      :$entries = 10,
      :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $crot := self!template-for($channel, 'additional');
        get-template-repository.refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        my $clog := self.clog($channel);

        # Get any additional entries
        my @entries = self!ready-entries-for-template(
          $clog
            .entries(:conversation, :until-target($target))
            .head($entries)
            .reverse,
          $channel, $clog.colors, :short
        );

        # Run all the plugins
        for @!live-plugins -> &plugin {
            &plugin.returns ~~ Nil
              ?? plugin(@entries)
              !! (@entries = plugin(@entries))
        }

        # Nothing before
        unless @entries {
            response.status = 204;
            return "";
        }

        my %params = :$channel, :@entries;
        create-result($crot, %params, $json);
    }

    # Return content for scroll-down entries
    method !scroll-down(
       $channel,
      :$target!,
      :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $crot := self!template-for($channel, 'additional');
        get-template-repository.refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        my $clog := self.clog($channel);

        # Get any additional entries
        my @entries = $clog.entries(:conversation, :from-target($target));
        if @entries < 1 {  # after server restart, there could no entries yet
            response.status = 204;
            return "";
        }

        # Ready the entries for the template
        @entries = self!ready-entries-for-template(
          @entries, $channel, $clog.colors, :short
        );
        @entries.shift;  # drop the target

        # Run all the plugins
        for @!live-plugins -> &plugin {
            &plugin.returns ~~ Nil
              ?? plugin(@entries)
              !! (@entries = plugin(@entries))
        }

        my %params = :$channel, :@entries;
        create-result($crot, %params, $json);
    }

    # Return content for live channel view
    method !live(
       $channel,
      :$entries-pp = 50,
      :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $crot := self!template-for($channel, 'live');
        get-template-repository.refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        my $clog := self.clog($channel);

        sub find-em() {
            if $clog.entries(
              :conversation, :reverse
            ).head($entries-pp) -> @found {
                self!ready-entries-for-template(
                  @found.reverse,
                  $channel,
                  $clog.colors,
                  :short
                )
            }
        }

        my $then    := now;
        my @entries  = find-em;
        my $elapsed := ((now - $then) * 1000).Int;

        # Run all the plugins
        for @!live-plugins -> &plugin {
            &plugin.returns ~~ Nil
              ?? plugin(@entries)
              !! (@entries = plugin(@entries))
        }

        my @dates := $clog.dates;
        my %params =
          channel             => $channel,
          channels            => @!channels,
          date                => @dates.tail,
          start-date          => @entries.head<date> // "",
          end-date            => @entries.tail<date> // "",
          first-date          => @dates.head,
          last-date           => @dates.tail,
          elapsed             => ((now - $then) * 1000).Int,
          entries             => @entries,
          entries-pp          => $entries-pp,
          first-target        => @entries.head<target> // "",
          last-target         => @entries.tail<target> // "",
          nr-entries          => @entries.elems,
        ;
        add-search-pulldown-values(%params);
        create-result($crot, %params, $json);
    }

    # Return content for searches
    method !search(
       $channel,
      :$nicks         = "",
      :$entries-pp    = 25,
      :$type          = "words",
      :$message-type  = "",  # control | conversation
      :$query         = "",
      :$from-yyyymmdd = "",
      :$from-year     = "",
      :$from-month    = "",
      :$from-day      = "",
      :$to-yyyymmdd   = "",
      :$to-year       = "",
      :$to-month      = "",
      :$to-day        = "",
      :$ignorecase    = "",
      :$all-words     = "",
      :$include-aliases = "",
      :$first-target = "",
      :$last-target  = "",
      :$first = "",
      :$last  = "",
      :$prev  = "",
      :$next  = "",
      :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $crot := self!template-for($channel, 'search');
        get-template-repository.refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        my $clog  := self.clog($channel);
        my @dates := $clog.dates;
        my @years := $clog.years;
        my $first-date := @dates.head // "";
        my $last-date  := @dates.tail // "";

        # Initial setup of parameters to clog.entries
        my %params;
        %params<all>           := True if $all-words;
        %params<ignorecase>    := True if $ignorecase;
        %params{$message-type} := True if $message-type;

        # Look for any period limitation
        my $from-date;
        if $from-yyyymmdd {
            $from-date = $from-yyyymmdd.Date;
        }
        elsif $from-year && $from-month && $from-day {
            $from-date = Date.new($from-year, $from-month, $from-day) // Nil;
        }
        my $to-date;
        if $to-yyyymmdd {
            $to-date = $to-yyyymmdd.Date;
        }
        elsif $to-year && $to-month && $to-day {
            $to-date = Date.new($to-year, $to-month, $to-day) // Nil;
        }

        # Handle period limitation
        if $from-date || $to-date {
            $from-date = @dates.head unless $from-date;
            $to-date   = @dates.tail unless $to-date;
            ($from-date, $to-date) = ($to-date, $from-date)
              if $to-date < $from-date;
            %params<dates> := $from-date.Date .. $to-date.Date
              unless $from-date eq $first-date && $to-date eq $last-date;
        }

        my $moving;
        my $produces-reversed;
        if $first {
            $moving := True;
        }
        elsif $last {
            %params<reverse>   := True;
            $produces-reversed := True;
            $moving            := True;
        }
        elsif $prev && $first-target {
            %params<before-target> := $first-target;
            $produces-reversed     := True;
            $moving                := True;
        }
        elsif $next && $last-target {
            %params<after-target> := $last-target;
            $moving               := True;
        }
        else {  # bare entry
            %params<reverse>   := True;
            $produces-reversed := True;
        }

        my str @errors;
        if $nicks {
            if $nicks.comb(/ \w+ /) -> @nicks {
                if @nicks.map({ $clog.aliases-for-nick($_).Slip }) -> @aliases {
                    %params<nicks> := $include-aliases ?? @aliases !! @nicks;
                }
                else {
                    @errors.push: "'@nicks' not known as nick(s)";
                }
            }
        }

        if $query && $query.words -> @words {
            if $type eq "words" | "contains" | "starts-with" {
                %params{$type} := @words;
            }
            elsif $type eq 'matches' {
                %params<matches> := $_ with string2regex($query);
            }
        }

        my $more;
        sub find-em() {
            my $fetch = $entries-pp + 1;
            if $clog.entries(|%params).head($fetch) -> @found {
                $more := @found == $fetch;
                self!ready-entries-for-template(
                  $produces-reversed
                    ?? @found.head($fetch).reverse
                    !! @found.head($fetch),
                  $channel,
                  $clog.colors,
                  :short
                )
            }
        }

        my $then    := now;
        my @entries  = find-em;
        my $elapsed := ((now - $then) * 1000).Int;

        if !@entries && $moving {
            response.status = 204;
            return "";
        }

        %params =
          all-words          => $all-words,
          control            => $message-type eq "control",
          conversation       => $message-type eq "conversation",
          channel            => $channel,
          channels           => @!channels,
          dates              => $clog.dates,
          elapsed            => ((now - $then) * 1000).Int,
          entries            => @entries,
          entries-pp         => $entries-pp,
          start-date         => (@entries ?? @entries.head<date> !! ""),
          end-date           => (@entries ?? @entries.tail<date> !! ""),
          first-date         => $first-date,
          first-human-date   => human-date($first-date),
          from-day           => $from-day,
          from-month         => $from-month,
          from-year          => $from-year || @years.head,
          from-yyyymmdd      => $from-yyyymmdd,
          ignorecase         => $ignorecase,
          include-aliases    => $include-aliases,
          last-date          => $last-date,
          last-human-date    => human-date($last-date),
          message-type       => $message-type,
          months             => @template-months,
          more               => $more,
          name               => $channel,
          nicks              => $nicks,
          nr-entries         => +@entries,
          query              => $query || "",
          to-day             => $to-day,
          to-month           => $to-month,
          to-year            => $to-year || @years.tail,
          to-yyyymmdd        => $to-yyyymmdd,
          type               => $type,
          years              => @years,
        ;
        add-search-pulldown-values(%params);
        create-result($crot, %params, $json);
    }

    proto method html(|) is implementation-detail {*}

    # Return an IO object for other HTML files in a channel
    multi method html($channel, $file --> IO:D) {
        my $template := $file.chop(5) ~ '.crotmp';

        my $dir  := $!static-dir.add($channel);
        my $html := $dir.add($file);
        my $crot := $!template-dir.add($channel).add($template);
        $crot := $!template-dir.add($template) unless $crot.e;

        # No template, if there's bare HTML, serve it
        if !$crot.e {
            $html.e ?? $html !! Nil
        }

        # May need to render
        else {
            if !$html.e                           # file does not exist
              || $html.modified < $!liftoff       # file is too old
                                | $crot.modified  # or template changed
            {
                $dir.mkdir;
                self!render: $!static-dir, $html, $crot, {
                  :$channel,
                }
            }
            $html
        }
    }

    # Return an IO object for other HTML files in root dir
    multi method html($file --> IO:D) {
        my $template := $file.chop(5) ~ '.crotmp';

        my $html := $!static-dir.add($file);
        my $crot := $!template-dir.add($template);

        # No template, if there's bare HTML, serve it
        if !$crot.e {
            $html.e ?? $html !! Nil
        }

        # May need to render
        else {
            if !$html.e                           # file does not exist
              || $html.modified < $!liftoff       # file is too old
                                | $crot.modified  # or template changed
            {
                self!render: $!static-dir, $html, $crot, {
                  channels => @!channels,
                }
            }
            $html
        }
    }

#--------------------------------------------------------------------------------
# Methods related to routing

    # Stopgap measure until we can ask Cro
    my constant %mime-types = Map.new((
      ''   => 'text/text; charset=UTF-8',
      css  => 'text/css; charset=UTF-8',
      html => 'text/html; charset=UTF-8',
      ico  => 'image/x-icon',
      json => 'text/json; charset=UTF-8',
    ));
    my constant $default-mime-type = %mime-types{''};

    # Return MIME type for a given IO
    sub mime-type(IO:D $io) {
        my $basename := $io.basename;
        with $basename.rindex('.') {
            %mime-types{$basename.substr($_ + 1)}
              // $default-mime-type
        }
        else {
            $default-mime-type
        }
    }

    # Return the clients Accept-Encoding
    sub accept-encoding() {
        with request.headers.first: *.name eq 'Accept-Encoding' {
            .value
        }
        else {
            ''
        }
    }

    # Serve the given IO as a static file
    multi sub serve-static(IO:D $io is copy, *%_) {
        dd $io.absolute;
#        if may-serve-gzip() {
#dd "serving zipped";
#            header 'Transfer-Encoding', 'gzip';
#            static self!gzip($io).absolute, |c, :mime-types({ 'gz' => mime-type($io) });
#            content mime-type($io), gzip($io).slurp(:bin);
#        }
#        else {
                    static $io.absolute, :%mime-types
#        }
    }
    multi sub serve-static($, *%) { not-found }

    # Return whether client accepts gzip
    method !may-serve-gzip() {
        $!zip-dir && accept-encoding.contains('gzip')
    }

    # Return IO for gzipped version of given IO
    method !gzip(IO:D $base-dir, IO:D $io) {
        my $io-absolute := $io.absolute;
        my $path := $io-absolute.substr($base-dir.absolute.chars);
        my $gzip := $!zip-dir.add($path ~ '.gz');
        if !$gzip.e || $gzip.modified < $io.modified {
            my $proc := run(
              'gzip', '--stdout', '--force', $io-absolute,
              :bin, :out
            );
            mkdir $gzip.parent;
            $gzip.spurt($proc.out.slurp, :bin);
        }
        $gzip
    }

    # Render text of given IO and template and make sure there is a
    # gzipped version for it as well if there's a place to store it
    method !render(
      IO:D $base-dir, IO:D $file, IO:D $crot, %params
    --> Nil) {

        # Remove cached template if it was changed
        get-template-repository.refresh($crot.absolute)
          if $file.e && $file.modified < $crot.modified;

        $file.parent.mkdir;
        $file.spurt: render-template $crot, %params;
        self!gzip($base-dir, $file) if $!zip-dir;
    }

    # Subsets for routing
    subset CSS  of Str  where *.ends-with('.css');
    subset HTML of Str  where *.ends-with('.html');
    subset LOG  of Str  where *.ends-with('.log');

    subset DAY of HTML where {
        try .IO.basename.substr(0,10).Date
    }
    subset YEAR of Str where {
        try .chars == 4 && .Int
    }
    subset MONTH of Str where {
        try .chars == 7
          && .substr(0,4).Int             # year ok
          && 0 <= .substr(5,2).Int <= 13  # month ok, allow for offset of 1
    }
    subset DATE of Str where {
        try .Date
    }

    # Return the actual Cro application to be served
    method application() {
        subset CHANNEL of Str where { $_ (elem) @!channels }

        route {
#            after { note .Str }   # show response headers
            get -> {
                redirect "/home.html", :permanent
            }
            get -> 'home.html' {
                serve-static self!home
            }
            get -> 'search.html', :$channel, :%args {
                content 'text/html', self!search($channel, |%args)
            }
            get -> 'search.json', :$channel, :%args {
                content 'text/json', self!search($channel, :json, |%args)
            }
            get -> 'around.html', :%args {
                content 'text/html', self!around(|%args)
            }
            get -> 'around.json', :%args {
                content 'text/json', self!around(:json, |%args)
            }

            get -> CHANNEL $channel {
                redirect "/$channel/index.html", :permanent
            }
            get -> CHANNEL $channel, '' {
                redirect "/$channel/index.html", :permanent
            }
            get -> CHANNEL $channel, 'index.html' {
                serve-static self!index($channel)
            }

            get -> CHANNEL $channel, 'live.html', :%args {
                content 'text/html', self!live($channel, |%args)
            }
            get -> CHANNEL $channel, 'live.json', :%args {
                content 'text/json', self!live($channel, :json, |%args)
            }

            get -> CHANNEL $channel, 'gist.html', :%args {
                content
                  'text/html',
                  self!gist($channel, %args.keys.first)         # XXX
            }
            get -> CHANNEL $channel, 'gist.json', :%args {
                content
                  'text/json',
                  self!gist($channel, %args.keys.first, :json)  # XXX
            }

            get -> CHANNEL $channel, 'scroll-down.html', :%args {
                content 'text/html', self!scroll-down($channel, |%args)
            }
            get -> CHANNEL $channel, 'scroll-down.json', :%args {
                content 'text/json', self!scroll-down($channel, :json, |%args)
            }

            get -> CHANNEL $channel, 'scroll-up.html', :%args {
                content 'text/html', self!scroll-up($channel, |%args)
            }
            get -> CHANNEL $channel, 'scroll-up.json', :%args {
                content 'text/json', self!scroll-up($channel, :json, |%args)
            }

            get -> CHANNEL $channel, 'search.html', :%args {
                content 'text/html', self!search($channel, |%args)
            }

            get -> CHANNEL $channel, 'today' {
                redirect "/$channel/"
                  ~ self.clog($channel).this-date(now.Date.Str)
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'first' {
                redirect "/$channel/"
                  ~ self.clog($channel).dates.head
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'last' {
                redirect "/$channel/"
                  ~ self.clog($channel).dates.tail
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'random' {
                redirect "/$channel/"
                  ~ self.clog($channel).dates.roll
                  ~ '.html';
            }

            get -> CHANNEL $channel, YEAR $year {
                my @dates := self.clog($channel).dates;
                redirect "/$channel/"
                  ~ (@dates[finds @dates, $year] || @dates.tail)
                  ~ '.html';
            }
            get -> CHANNEL $channel, MONTH $month {
                my @dates := self.clog($channel).dates;
                redirect "/$channel/"
                  ~ (@dates[finds @dates, $month] || @dates.tail)
                  ~ '.html';
            }

            get -> CHANNEL $channel, 'prev', DATE $date {
                with self.clog($channel).prev-date($date) -> $prev {
                    redirect "/$channel/$prev.html", :permanent
                }
                else {
                    redirect "/$channel/$date.html"
                }
            }
            get -> CHANNEL $channel, 'this', DATE $date {
                redirect "/$channel/"
                  ~ self.clog($channel).this-date($date.Str)
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'next', DATE $date {
                with self.clog($channel).next-date($date) -> $next {
                    redirect "/$channel/$next.html", :permanent
                }
                else {
                    redirect "/$channel/$date.html"
                }
            }

            get -> CHANNEL $channel, DAY $file {
                serve-static self!day($channel, $file);
            }
            get -> CHANNEL $channel, HTML $file {
                serve-static self.html($channel, $file);
            }
            get -> CHANNEL $channel, LOG $file {
                my $io := $!log-dir
                  .add($channel)
                  .add($file.substr(0,4))
                  .add($file.chop(4));

                serve-static $io
            }
            get -> CHANNEL $channel, $file {
                my $io := $!static-dir.add($channel).add($file);
                serve-static $io.e ?? $io !! $!static-dir.add($file)
            }
            get -> HTML $file {
                serve-static self.html($file)
            }

            get -> $file {
                serve-static $!static-dir.add($file)
            }

            get -> |c {
                dd c;
                not-found
            }
        }
    }
}

=begin pod

=head1 NAME

App::IRC::Log - Cro application for presentating IRC logs

=head1 SYNOPSIS

=begin code :lang<raku>

use App::IRC::Log;

my $ail := App::IRC::Log.new:
  :$log-class,
  :$log-dir,
  :$rendered-dir,
  :$state-dir,
  :$static-dir,
  :$template-dir,
  :$zip-dir,
  colorize-nick => &colorize-nick,
  htmlize       => &htmlize,
  day-plugins   => day-plugins(),
  channels      => @channels,
;

my $service := Cro::HTTP::Server.new:
  :application($ail.application),
  :$host, :$port,
;
$service.start;

react whenever signal(SIGINT) {
    $service.stop;
    $ail.shutdown;
    exit;
}

=end code

=head1 DESCRIPTION

App::IRC::Log is a class for implementing an application to show IRC logs.

It is still heavily under development and may change its interface at any
time.

It is currently being used to set up a website for showing the historical
IRC logs of the development of the Raku Programming Language (see
C<App::Raku::Log>).

=head1 AUTHOR

Elizabeth Mattijsen <liz@raku.rocks>

Source can be located at: https://github.com/lizmat/App-IRC-Log . Comments and
Pull Requests are welcome.

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
