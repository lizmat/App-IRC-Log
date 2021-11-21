use Array::Sorted::Util:ver<0.0.8>:auth<zef:lizmat>;
use Cro::HTTP::Router:ver<0.8.7>;
use Cro::WebApp::Template:ver<0.8.7>;
use Cro::WebApp::Template::Repository:ver<0.8.7>;
use JSON::Fast:ver<0.16>;
use RandomColor;

# Array for humanizing dates
my constant @human-months = <?
  January February March April May June July
  August September October November December
>;

# Month pulldown
my constant @template-months = (1..12).map: {
    $_ => @human-months[$_].substr(0,3)
}

# Turn a YYYY-MM-DD date into a human readable date
sub human-date(str $date, str $del = ' ', :$short) {
    if $date {
        my $month := @human-months[$date.substr(5,2)];
        $date.substr(8,2).Int
          ~ $del
          ~ ($short ?? $month.substr(0,3) !! $month)
          ~ $del
          ~ $date.substr(0,4)
    }
}

# Turn a YYYY-MM-DD date into a human readable month
sub human-month(str $date, str $del = ' ', :$short) {
    if $date {
        my $month := @human-months[$date.substr(5,2)];
        ($short ?? $month.substr(0,3) !! $month)
          ~ $del
          ~ $date.substr(0,4)
    }
}

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

# Role to mark channel names as divider or not
my role Divider { has $.divider }

#-------------------------------------------------------------------------------
# App::IRC::Log class

class App::IRC::Log:ver<0.0.45>:auth<zef:lizmat> {
    has         $.channel-class is required;  # IRC::Channel::Log compatible
    has         $.log-class     is required;  # IRC::Log compatible
    has IO()    $.log-dir       is required;  # IRC-logs
    has IO()    $.static-dir    is required;  # static files, e.g. favicon.ico
    has IO()    $.template-dir  is required;  # templates
    has IO()    $.rendered-dir  is required;  # renderings of template
    has IO()    $.state-dir     is required;  # saving state
    has IO()    $.zip-dir;                    # saving zipped renderings
    has         &.colorize-nick is required;  # colorize a nick in HTML
    has         &.htmlize       is required;  # make HTML of message of entry
    has         &.special-entry;              # optional special entry? checker
    has Instant $.liftoff is built(:bind) = $*INIT-INSTANT;
    has Str     @.channels = self.default-channels;  # channels to provide
    has         @.live-plugins;        # any plugins for live view
    has         @.day-plugins;         # any plugins for day view
    has         @.search-plugins;      # any plugins for search view
    has         @.gist-plugins;        # any plugins for gist view
    has         @.scrollup-plugins;    # any plugins for scrollup messages
    has         @.scrolldown-plugins;  # any plugins for scrolldown messages
    has         %.descriptions;  # long channel descriptions
    has         %.one-liners;    # short channel descriptions
    has         %!clogs;         # hash of IRC::Channel::Log objects

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
    submethod TWEAK(
      :$degree is copy,
      :$batch  is copy,
    --> Nil) {
        $degree := Kernel.cpu-cores +> 1 without $degree;
        $batch  := 16                    without $batch;

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

        # Mark channel dividers
        @!channels = @!channels.map: {
            $_ but Divider(.starts-with('-') ?? .substr(1) !! "")
        }

        for @!channels.race(:1batch, :$degree).map( {
             unless .divider {  # dont do visual dividers
                 my $clog := $!channel-class.new:
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
                            $last-date = .date;
                        }
                    }
                }

                $clog
            }
        } ) {
            say "Loaded $_.name()";
            %!clogs{.name} := $_;
        }
    }

    # Perform all actions associated with shutting down.
    # Expected to be run *after* the application has stopped.
    method shutdown(App::IRC::Log:D: --> Nil) {
        self.clog($_).shutdown for @!channels;
    }

#-------------------------------------------------------------------------------
# Methods related to rendering

    # Return IRC::Channel::Log object for given channel
    method clog(App::IRC::Log:D: str $channel) {
        %!clogs{$channel} // Nil
    }

    # Set up entries for use in template
    method !ready-entries-for-template(\entries, $channel, %colors, :$short) {
        my str $last-date = "";
        my str $last-hhmm = "";
        my str $last-nick = "";
        my int $last-type = -1;
        entries.map: {
            my str $date = .date;
            my str $hhmm = .hh-mm // "";
            my str $nick = .nick  // "";
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
            $nick && $nick eq $last-nick
              ?? (%hash<same-nick> := True)
              !! (%hash<initial>   := True);

            %hash<control> := True if .control;

            if .conversation {
                %hash<conversation>   := True;
                %hash<self-reference> := True
                  if .^name.ends-with('Self-Reference');
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

    # Return the previous conversation entry for given clog and entry, if any
    method !previous-conversation-entry($clog, $initial-entry) {
        my $entry = $initial-entry.prev;
        while $entry && !$entry.conversation {
            $entry = $entry.prev;
        }
        unless $entry {
            my $date := $clog.prev-date($initial-entry.date.Str);
            while $date {
                $entry = $clog.log($date).last-entry;
                while $entry && !$entry.conversation {
                    $entry = $entry.prev;
                }
                $date := $entry
                  ?? Nil
                  !! $clog.prev-date($date);
            }
        }
        $entry
    }

    # Make sure that no entry combining post-processing gets incomplete info
    method !check-incomplete-special-entries($clog, @entries) {
        my int $added;
        with &!special-entry -> &is-special {
            my $entry := @entries.head;
            my int $ok-seen;
            while ($entry := self!previous-conversation-entry($clog, $entry))
              && $ok-seen < 3 {
                @entries.unshift($entry);
                is-special($entry) ?? ($ok-seen = 0) !! ++$ok-seen;
                ++$added;
            }
        }
        $added
    }

    # Run all the plugins
    method !run-plugins(@plugins, @entries) {
        if @entries {
            for @plugins -> &plugin {
                &plugin.returns ~~ Nil
                  ?? plugin(@entries)
                  !! (@entries = plugin(@entries))
            }
        }
    }

    # Return IO object for given channel and day
    method !day($channel, $date --> IO:D) {
        my $Date := $date.Date;
        my $year := $date.substr(0,4);
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
            self!run-plugins(@!day-plugins, @entries);

            # Set up parameters
            my %params =
              channel      => $channel,
              active       => $clog.active,
              description  => %!descriptions{$channel},
              descriptions => %!descriptions,
              one-liner    => %!one-liners{$channel},
              one-liners   => %!one-liners,
              channels     => @!channels,
              date         => $date,
              human-date   => human-date($date),
              month        => $date.substr(0,7),
              next-date    => $Date.later(:1day),
              next-month   => $date.substr(0,7).succ,
              next-year    => $date.substr(0,4).succ,
              prev-date    => $Date.earlier(:1day),
              prev-month   => $clog.is-first-date-of-month($date)
                ?? "this/$Date.earlier(:1month).first-date-in-month()"
                !! $date.substr(0,7),
              prev-year    => $clog.is-first-date-of-year($date)
                ?? 'this/' ~ Date.new($Date.year - 1, 1, 1)
                !! $date.substr(0,4),
              start-date   => $date,
              end-date     => $date,
              first-date   => @dates.head,
              last-date    => @dates.tail,
              entries      => @entries
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
            self!render-to-file: $!rendered-dir, $html, $crot, %params;
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
            my str $very-first-date = '9999-12-31';
            my str $very-last-date  = '0000-01-01';
            my @channel-info = @!channels.map: -> $channel {
                if $channel.divider -> $divider {
                    Map.new((:$divider))
                }
                else {
                    my $clog  := self.clog($channel);
                    my @dates := $clog.dates;

                    my str $last-yyyy-mm;
                    my @months;
                    my @years;

                    sub finish-year(--> Nil) {
                        if @months {
                            @years[@years.elems] := Map.new((
                              channel => $channel,
                              year    => $last-yyyy-mm.substr(0,4),
                              months  => @months.List,
                            ));
                            @months = ();
                        }
                    }

                    for @dates -> $date {
                        my str $yyyy-mm = $date.substr(0,7);

                        # new month
                        if $yyyy-mm ne $last-yyyy-mm {
                            finish-year
                              if !$last-yyyy-mm.starts-with($date.substr(0,4));
                            @months.push: Map.new((
                              channel     => $channel,
                              month       => $yyyy-mm,
                              human-month =>
                                @human-months[$yyyy-mm.substr(5,2)].substr(0,3),
                            ));
                            $last-yyyy-mm = $yyyy-mm;
                        }
                    }
                    finish-year;

                    my $first-date := @dates.head;
                    my $last-date  := @dates.tail;
                    $very-first-date min= $first-date;
                    $very-last-date  max= $last-date;

                    Map.new((
                      divider          => "",
                      active           => $clog.active,
                      name             => $channel,
                      description      => %!descriptions{$channel} // "",
                      one-liner        => %!one-liners{$channel}   // "",
                      years            => @years,
                      start-date       => $last-date,
                      end-date         => $last-date,
                      first-date       => $first-date,
                      first-human-date => human-date($first-date),
                      last-date        => $last-date,
                      last-human-date  => human-date($last-date),
                      month            => $last-date.substr(0,7),
                    ))
                }
            }

            my %params =
              first-date       => $very-first-date,
              first-human-date => human-date($very-first-date),
              last-date        => $very-last-date,
              last-human-date  => human-date($very-last-date),
              start-date       => $very-first-date,
              end-date         => $very-last-date,
              channel-info     => @channel-info,
              channel          => "",   # prevent warnings
              channels         => @!channels,
              description      => %!descriptions<__home__> // "",
            ;
            add-search-pulldown-values(%params);
            self!render-to-file: $!rendered-dir, $html, $crot, %params;
        }
        $html
    }

    method !template-for(str $channel, str $name) {
        my str $filename = $name ~ '.crotmp';
        my $crot := $!template-dir.add($channel).add($filename);
        $crot := $!template-dir.add: $filename unless $crot.e;

        get-template-repository.refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        $crot
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
                      month       => $last-yyyy-mm.clone,
                      human-month => @human-months[$last-yyyy-mm.substr(5,2)],
                      dates       => @days.List,
                    ));
                    @days = ();
                }
            }

            sub finish-year(--> Nil) {
                if @months {
                    @years[@years.elems] := Map.new((
                      channel => $channel,
                      year    => $last-yyyy-mm.substr(0,4),
                      months  => @months.List,
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
              active           => $clog.active,
              channels         => @!channels,
              description      => %!descriptions{$channel},
              descriptions     => %!descriptions,
              one-liner        => %!one-liners{$channel},
              one-liners       => %!one-liners,
              years            => @years,
              start-date       => $last-date,
              end-date         => $last-date,
              first-date       => $first-date,
              first-human-date => human-date($first-date),
              last-date        => $last-date,
              last-human-date  => human-date($last-date),
            ;
            add-search-pulldown-values(%params);

            self!render-to-file: $!rendered-dir, $html, $crot, %params;
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
        my $clog := self.clog($channel);

        my %params;
        %params<channel>       := $channel;
        %params<around-target> := $target;
        %params<nr-entries>    := $nr-entries   if $nr-entries;
        %params<control>       := $control      if $control;
        %params<conversation>  := $conversation if $conversation;

        my @entries = self!ready-entries-for-template(
           $clog.entries(|%params), $channel, $clog.colors, :short
        );

        .<is-target> := True
          given @entries[@entries.first: *.<target> eq $target, :k];

        %params =
          channel  => $channel,
          channels => @!channels,
          dates    => $clog.dates,
          target   => $target,
          entries  => @entries,
        ;

        self!create-result(
          self!template-for($channel, 'around'),
          %params,
          $json
        )
    }

    # Return content for gist helper
    method !gist(
       $channel,
       $targets?,
      :$json,
    ) {
        my $crot := self!template-for($channel, 'gist');
        my $clog  := self.clog($channel);
        my @dates := $clog.dates;

        my str @targets = $targets.split(",");
        my %params;
        %params<channel> := $channel;
        %params<targets> := @targets;

        my @entries = self!ready-entries-for-template(
          $clog.entries(|%params), $channel, $clog.colors, :short
        );
        self!run-plugins(@!gist-plugins, @entries);

        my $last-date := @dates.tail;

        %params =
          channel      => $channel,
          active       => $clog.active,
          description  => %!descriptions{$channel},
          descriptions => %!descriptions,
          one-liner    => %!one-liners{$channel},
          one-liners   => %!one-liners,
          channels     => @!channels,
          first-date   => @dates.head,
          last-date    => $last-date,
          targets      => @targets,
          entries      => @entries,
          month        => $last-date.substr(0,7),
        ;

        if @entries {
            my $first-gist-date := @entries.head<date>;
            %params<start-date> := $first-gist-date,
            %params<end-date>   := @entries.tail<date>;
            %params<month>      := $first-gist-date.substr(0,7);
        }
        add-search-pulldown-values(%params);
        self!create-result($crot, %params, $json)
    }

    # Return content for scroll-up entries
    method !scroll-up(
             $channel,
            :$target!,
      Int() :$entries = 10,
            :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $clog := self.clog($channel);

        if $clog.entries(
          :conversation, :le-target($target), :$entries, :reverse
        ) -> @entries is copy {
            self!check-incomplete-special-entries($clog, @entries);
            @entries = self!ready-entries-for-template(
              @entries, $channel, $clog.colors, :short
            );
            self!run-plugins(@!scrollup-plugins, @entries);

            self!create-result(
              self!template-for($channel, 'additional'),
              %(:$channel, :@entries),
              $json
            )
        }
        else {
            response.status = 204;
            ""
        }

    }

    # Return content for scroll-down entries
    method !scroll-down(
       $channel,
      :$target!,
      :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $clog := self.clog($channel);

        # Get any additional entries
        my @entries = $clog.entries(:conversation, :ge-target($target));

        # Ready the entries for the template
        if @entries > 1 {
            @entries = self!ready-entries-for-template(
              @entries, $channel, $clog.colors, :short
            );
            self!run-plugins(@!scrolldown-plugins, @entries);
            @entries.shift;  # drop the target

            self!create-result(
              self!template-for($channel, 'additional'),
              %(:$channel, :@entries),
              $json
            )
        }
        else {
            response.status = 204;
            ""
        }
    }

    # Return content for live channel view
    method !live(
       $channel,
      :$entries-pp = 50,
      :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $clog := self.clog($channel);
        my @entries = $clog.entries(
          :conversation, :entries($entries-pp), :reverse
        );
        self!check-incomplete-special-entries($clog, @entries);

        # Convert to hashes
        @entries = self!ready-entries-for-template(
          @entries, $channel, $clog.colors, :short
        );
        self!run-plugins(@!live-plugins, @entries);

        my @dates     := $clog.dates;
        my $last-date := @dates.tail;
        my %params =
          channel      => $channel,
          active       => $clog.active,
          channels     => @!channels.grep({ self.clog($_).active }).List,
          date         => @dates.tail,
          start-date   => @entries.head<date> // "",
          end-date     => @entries.tail<date> // "",
          first-date   => @dates.head,
          last-date    => $last-date,
          entries      => @entries,
          entries-pp   => $entries-pp,
          first-target => @entries.head<target> // "",
          last-target  => @entries.tail<target> // "",
          nr-entries   => @entries.elems,
          month        => $last-date.substr(0,7),
        ;

        add-search-pulldown-values(%params);
        self!create-result(
          self!template-for($channel, 'live'),
          %params,
          $json
        )
    }

    # Return content for searches
    method !search(
             $channel is copy,
            :$nicks         = "",
      Int() :$entries-pp    = 25,
            :$type          = "words",
            :$message-type  = "",  # control | conversation
            :$query         = "",
            :$from-yyyymmdd = "",
            :$to-yyyymmdd   = "",
            :$ignorecase    = "",
            :$all-words     = "",
            :$include-aliases = "",
            :$le-target  = "",
            :$ge-target  = "",
            :$json,      # return as JSON instead of HTML
    --> Str:D) {
        $channel   = @!channels.head unless $channel;
        my $clog  := self.clog($channel);
        my @dates := $clog.dates;
        my @years := $clog.years;
        my str $first-date = @dates.head // "";
        my str $last-date  = @dates.tail // "";

        # Initial setup of parameters to clog.entries
        my %params;
        %params<all>           := True if $all-words;
        %params<ignorecase>    := True if $ignorecase;
        %params{$message-type} := True if $message-type;

        my $scrolling := False;
        my $reverse   := True;
        if $le-target {
            %params<le-target> := $le-target;
        }
        elsif $ge-target {
            %params<ge-target> := $ge-target;
            $reverse           := False;
        }
        else {
            # Handle period limitation
            my str $from-date = $from-yyyymmdd || $first-date;
            my str $to-date   = $to-yyyymmdd   || $last-date;
            ($from-date, $to-date) = ($to-date, $from-date)
              if $to-date lt $from-date;
            $from-date max= $first-date;
            $to-date   min= $last-date;

            %params<dates> := $from-date.Date .. $to-date.Date
              unless $from-date eq $first-date && $to-date eq $last-date;
        }

        if $nicks {
            if $nicks.comb(/ \w+ /) -> @nicks {
                if @nicks.map({ $clog.aliases-for-nick($_).Slip }) -> @aliases {
                    %params<nick-names> := $include-aliases ?? @aliases !! @nicks;
                }
            }
        }

        if $query {
            if $type eq "words" | "contains" | "starts-with" {
                if $query.words -> @words {
                    %params{$type} := @words;
                }
            }
            elsif $type eq 'matches' {
                %params<matches> := $_ with string2regex($query);
            }
        }

        sub find-em() {
            if $clog.entries(
              |%params, :$reverse, :entries($entries-pp)
            ) -> @found {
                self!ready-entries-for-template(
                  @found, $channel, $clog.colors, :short
                )
            }
        }

        my @entries = find-em;
        self!run-plugins(@!search-plugins, @entries);
        if $le-target || $ge-target {
            if @entries > 1 {
                @entries.shift if $ge-target;  # drop the target
                self!create-result(
                  self!template-for($channel, 'additional'),
                  %(:$channel, :@entries),
                  $json
                )
            }
            else {
                response.status = 204;
                return "";
            }
        }
        else {
            %params =
              all-words        => $all-words,
              control          => $message-type eq "control",
              conversation     => $message-type eq "conversation",
              channel          => $channel,
              active           => $clog.active,
              channels         => @!channels,
              description      => %!descriptions{$channel},
              descriptions     => %!descriptions,
              one-liner        => %!one-liners{$channel},
              one-liners       => %!one-liners,
              dates            => @dates,
              entries          => @entries,
              entries-pp       => $entries-pp,
              start-date       => (@entries ?? @entries.head<date> !! ""),
              end-date         => (@entries ?? @entries.tail<date> !! ""),
              first-date       => $first-date,
              first-human-date => human-date($first-date),
              from-yyyymmdd    => $from-yyyymmdd,
              ignorecase       => $ignorecase,
              include-aliases  => $include-aliases,
              last-date        => $last-date,
              last-human-date  => human-date($last-date),
              message-type     => $message-type,
              month            => $last-date.substr(0,7),
              months           => @template-months,
              name             => $channel,
              nicks            => $nicks,
              nr-entries       => +@entries,
              query            => $query || "",
              to-yyyymmdd      => $to-yyyymmdd,
              type             => $type,
              years            => @years,
            ;
            add-search-pulldown-values(%params);

            self!create-result(
              self!template-for($channel, 'search'),
              %params,
              $json
            )
        }
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
                self!render-to-file: $!static-dir, $html, $crot, {
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
            my \then := now;
            my $proc := run(
              'gzip', '--stdout', '--force', $io-absolute,
              :bin, :out
            );
            mkdir $gzip.parent;
            $gzip.spurt($proc.out.slurp, :bin);
            note "{ ((now - then) * 1000).Int } msecs zipping";
        }
        $gzip
    }

    # Render given template and parameters
    method !render($crot, %params) {
        my \then := now;
        my $html := render-template $crot, %params;
        note "{ ((now - then) * 1000).Int } msecs rendering $crot.basename()";
        $html
    }

    # Render text of given IO and template and make sure there is a
    # gzipped version for it as well if there's a place to store it
    method !render-to-file(
      IO:D $base-dir, IO:D $file, IO:D $crot, %params
    --> Nil) {


        # Remove cached template if it was changed
        get-template-repository.refresh($crot.absolute)
          if $file.e && $file.modified < $crot.modified;

        $file.parent.mkdir;
        {
            my %warnings is BagHash;
            CONTROL {
                when CX::Warn {
                    %warnings.add(.message);
                    .resume;
                }
            }
            $file.spurt: self!render($crot, %params);
            if %warnings {
                for %warnings.sort(*.key) -> (:key($message), :value($seen)) {
                    note $seen > 1
                      ?? $seen ~ "x $message"
                      !! $message;
                }
            }
        }
        self!gzip($base-dir, $file) if $!zip-dir;
    }

    # Create result given template, parameters and json flag
    method !create-result($crot, %params, $json) {
        $json
          ?? to-json(%params,:!pretty)
          !! self!render($crot, %params)
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
        subset CHANNEL of Str where { %!clogs{$_}:exists }

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
                my $clog := self.clog($channel);
                my $date := $file.chop(5);
                $clog.log($date)
                  ?? serve-static self!day($channel, $date)
                  !! redirect "/$channel/$clog.this-date($date).html";
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

App::IRC::Log - Cro application for presenting IRC logs

=head1 SYNOPSIS

=begin code :lang<raku>

use App::IRC::Log;

my $ail := App::IRC::Log.new:
  :$channel-class,  # IRC::Channel::Log compatible class
  :$log-class,      # IRC::Log compatible class
  :$log-dir,
  :$rendered-dir,
  :$state-dir,
  :$static-dir,
  :$template-dir,
  :$zip-dir,
  colorize-nick => &colorize-nick,
  htmlize       => &htmlize,
  special-entry => &special-entry,
  channels      => @channels,
  live-plugins       => live-plugins(),
  day-plugins        => day-plugins(),
  search-plugins     => search-plugins(),
  gist-plugins       => gist-plugins(),
  scrollup-plugins   => scrollup-plugins(),
  scrolldown-plugins => scrolldown-plugins(),
  descriptions       => %descriptions,
  one-liners         => %one-liners,
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
