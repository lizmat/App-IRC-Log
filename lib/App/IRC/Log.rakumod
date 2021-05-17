use v6.*;

use Array::Sorted::Util:ver<0.0.6>:auth<cpan:ELIZABETH>;
use Cro::HTTP::Router:ver<0.8.5>;
use Cro::WebApp::Template:ver<0.8.5>;
use Cro::WebApp::Template::Repository:ver<0.8.5>;
use IRC::Channel::Log:ver<0.0.21>:auth<cpan:ELIZABETH>;
use JSON::Fast:ver<0.15>;
use RandomColor;

#-------------------------------------------------------------------------------
# Stuff related to routing

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

# Return IO for gzipped version of given IO
sub gzip(IO:D $io) {
    my $gzip := $io.sibling($io.basename ~ '.gz');
    run('gzip', '--keep', '--force', $io.absolute)
      if !$gzip.e || $gzip.modified < $io.modified;
    $gzip
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

# Return whether client accepts gzip
sub may-serve-gzip() {
    accept-encoding.contains('gzip')
}

# Render HTML given IO and template and make sure there is a
# gzipped version for it as well
sub render(IO:D $html, IO:D $crot, %_ --> Nil) {
    get-template-repository().refresh($crot.absolute)
      if $html.e && $html.modified < $crot.modified;
    $html.spurt: render-template $crot, %_;
    gzip($html);
}

# Serve the given IO as a static file
multi sub serve-static(IO:D $io is copy, *%_) {
dd $io.absolute;
#    if may-serve-gzip() {
#dd "serving zipped";
#        header 'Transfer-Encoding', 'gzip';
#        static gzip($io).absolute, |c, :mime-types({ 'gz' => mime-type($io) });
#        content mime-type($io), gzip($io).slurp(:bin);
#    }
#    else {
            static $io.absolute, :%mime-types
#    }
}
multi sub serve-static($, *%) { not-found }

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

#-------------------------------------------------------------------------------
# Stuff for creating values for templates

# Hash for humanizing dates
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
  12 => "Dec";

# Nicks that shouldn't be highlighted in text, because they probably
# are *not* related to that nick.
my constant %stop-nicks = <
  afraid agree alias all alpha alright also and anonymous any
  args around audience average banned bash beep beta block
  browser byte camelia cap change channels complex computer
  concerned confused connection con constant could cpan
  curiosity curious dead decent delimited dev did direction echo
  else embed engine everything failure fine finger food for fork
  fun function fwiw get good google grew hawaiian hello help hey
  hide his hmm hmmm hope host huh info interested its java jit
  juicy just keyboard kill lambda last life like literal little
  log looking lost mac man manner match max mental mhm mind moar
  moose name need never new niecza nobody nothing old one oops
  panda parrot partisan partly patch perl perl5 perl6 pizza
  promote programming properly pun python question raku rakudo
  rakudobug really regex register release repl return rid robot
  root sad sat signal simple should some somebody someone soon
  sorry space spam spawn spine spot still stop subroutine
  success such synthetic system systems tag tea test tester
  testing tests the there they think this total trick trigger
  try twigil type undefined unix user usr variable variables
  visiting wake was welcome what when who will writer yes
>.map: { $_ => True }

# Default color generator
sub generator($) {
    RandomColor.new(:luminosity<bright>).list.head
}

# Create HTML to colorize a word as a nick
sub colorize-nick(Str() $nick, %colors) {
    if %colors{$nick} -> $color {
        '<span style="color: ' ~ $color ~ '">' ~ $nick ~ '</span>'
    }
    else {
        $nick
    }
}

# Delimiters in message to find nicks to highlight
my constant @delimiters = ' ', '<', '>', |< : ; , + >;

# Create HTML version of a given entry
sub htmlize($entry, %colors) {
    my $text = $entry.message;

    # Something with a text
    if $entry.conversation {

        # An invocation of Camelia, assume it's code
        if $text.starts-with("m: ") {
            $text = $text.substr(0,3)
              ~ '<div id="code">'
              ~ $text.substr(3)
              ~ '</div>';
        }

        # Do the various tweaks
        else {

            # URL linking
            $text .= subst(
              / https? '://' \S+ /,
              { '<a href="' ~ $/~ '">' ~ $/ ~ '</a>' },
              :global
            );

            # Nick highlighting
            if $entry.^name.ends-with("Topic") {
                $text .= subst(/ ^ \S+ /, { colorize-nick($/, %colors) });
            }
            else {
                my str $last-del = ' ';
                $text = $text.split(@delimiters, :v).map(-> $word, $del = '' {
                    my $mapped := $word.chars < 3
                      || %stop-nicks{$word.lc}
                      || $last-del ne ' '
                      ?? $word ~ $del
                      !! colorize-nick($word, %colors) ~ $del;
                    $last-del = $del;
                    $mapped
                }).join;
            }

            # Thought highlighting
            if $entry.^name.ends-with("Self-Reference")
              || $text.starts-with(".oO(") {
                $text = '<div id="thought">' ~ $text ~ '</div>'
            }
        }
    }

    # No text, just do the nick highlighting
    else {
        $text .= subst(/^ \S+ /, { colorize-nick($/, %colors) });

        if $entry.^name.ends-with("Nick-Change") {
            $text .= subst(/ \S+ $/, { colorize-nick($/, %colors) });
        }
        elsif $entry.^name.ends-with("Kick") {
            $text .= subst(/ \S+ $/, { colorize-nick($/, %colors) }, :5th)
        }
    }
    $text
}

# Determine default channels from a given directory
my sub default-channels(IO:D $log-dir) {
    $log-dir.dir.map({ 
      .basename
      if .d
      && !.basename.starts-with('.')
      && .dir(:test(/ ^ \d\d\d\d $ /)).elems
    }).sort
}

#-------------------------------------------------------------------------------
# App::IRC::Log class
#
class App::IRC::Log:ver<0.0.1>:auth<cpan:ELIZABETH> {
    has         $.log-class     is required is built(:bind);
    has IO()    $.log-dir       is required;
    has IO()    $.html-dir      is required;
    has IO()    $.templates-dir is required;
    has IO()    $.state-dir     is required;
    has         &.htmlize     is built(:bind) = &htmlize;
    has Instant $.liftoff     is built(:bind) = $?FILE.words.head.IO.modified;
    has str     @.channels = default-channels($!log-dir);
    has         %!channels;

    my constant $nick-colors-json = 'nicks.json';

    # Start loading the logs asynchronously.  No need to be thread-safe
    # here as here will only be the thread creating the object.
    submethod TWEAK(--> Nil) {
        %!channels{$_} := start {
            my $clog := IRC::Channel::Log.new:
              logdir    => $!log-dir.add($_),
              class     => $!log-class,
              generator => &generator,
              state     => $!state-dir.add($_),
              name      => $_;
            $clog.watch-and-update if $clog.active;
            $clog;
        } for @!channels;
    }

    # Perform all actions associated with shutting down.
    # Expected to be run *after* the application has stopped.
    method shutdown(App::IRC::Log:D: --> Nil) {
        self.clog($_).shutdown for @!channels;
    }

    # Return IRC::Channel::Log object for given channel
    method clog(App::IRC::Log:D: str $channel --> IRC::Channel::Log:D) {

        # Even though this could be called from several threads
        # simultaneously, the key should always exist, so there
        # is no danger of messing up the hash.  The only thing
        # that can happen, is binding the result of the Promise
        # more than once to the hash.
        given %!channels{$channel} {
            if $_ ~~ Promise {
                %!channels{$channel} := .result  # not ready yet
            }
            else {
                $_ // Nil                        # ready, so go!
            }
        }
    }

    # Set up entries for use in template
    method !ready-entries-for-template(\entries, $channel, %colors, :$short) {
        my str $last-date = "";
        entries.map: {
            my str $date = .date.Str;
            my $hash := Hash.new((
              channel      => $channel,
              control      => .control,
              conversation => .conversation,
              date         => $date,
              hh-mm        => .hh-mm,
              hour         => .hour,
              human-date   =>  $date eq $last-date
                                 ?? ""
                                 !! human-date($date, "\xa0", :$short),
              message      =>  &!htmlize($_, %colors),
              minute       => .minute,
              ordinal      => .ordinal,
              sender       =>  colorize-nick(.sender, %colors),
              target       => .target.substr(11),
            ));
            $last-date = $date;
            $hash
        }
    }

    # Return IO object for given channel and day
    method !day($channel, $file --> IO:D) {
        my $date := $file.chop(5);
        my $Date := $date.Date;
        my $dir  := $!html-dir.add($channel).add($Date.year);
        my $html := $dir.add($date ~ '.html');
        my $crot := $!templates-dir.add('day.crotmp');

        # Need to (re-)render
        if !$html.e                           # file does not exist
          || $html.modified < $!liftoff       # file is too old
                            | $crot.modified  # or template changed
        {

            # Fetch the log and nick coloring
            my $clog   := self.clog($channel);
            my $log    := $clog.log($date);
            my %colors := $clog.colors;

            # Set up entries for use in template
            my @entries =
              self!ready-entries-for-template($log.entries, $channel, %colors);

            # Merge control messages inside the same minute
            my $merging;
            for @entries.kv -> $index, %entry {
                if %entry<ordinal> {
                    if %entry<control> {
                        if $merging || @entries[$index - 1]<control> {
                            $merging = $index - 1 without $merging;
                            @entries[$merging]<message> ~= ", %entry<message>";
                            @entries[$index] = Any;
                        }
                    }
                    else {
                        $merging = Any;
                    }
                }
                else {
                    $merging = Any;
                }
            }
            @entries = @entries.grep(*.defined);

            # Render it!
            $dir.mkdir;
            render $html, $crot, {
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
              :@entries
            }
        }
        $html
    }

    # Return an IO object for /home.html
    method !home(--> IO:D) {
        my $html := $!html-dir.add('home.html');
        my $crot := $!templates-dir.add('home.crotmp');

        if !$html.e                           # file does not exist
          || $html.modified < $!liftoff       # file is too old
                            | $crot.modified  # or template changed
        {
            my @channels = @!channels.map: -> $channel {
                my $clog  := self.clog($channel);
                my @dates  = $clog.dates;
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
                Map.new((
                  name             => $channel,
                  years            => @years,
                  first-date       => @dates.head,
                  first-human-date => human-date(@dates.head),
                  last-date        => @dates.tail,
                  last-human-date  => human-date(@dates.tail),
                ))
            }

            render $html, $crot, {
              channels => @channels,
            }
        }
        $html
    }

    # Return an IO object for /channel/index.html
    method !index(str $channel --> IO:D) {
        my $html := $!html-dir.add($channel).add('index.html');
        my $crot := $!templates-dir.add($channel).add('index.crotmp');
        $crot := $!templates-dir.add('index.crotmp') unless $crot.e;

        if !$html.e                           # file does not exist
          || $html.modified < $!liftoff       # file is too old
                            | $crot.modified  # or template changed
        {
            my $clog  := self.clog($channel);
            my @dates  = $clog.dates;
            my %months = @dates.categorize: *.substr(0,7);
            my %years  = %months.categorize: *.key.substr(0,4);
            my @years  = %years.sort(*.key).reverse.map: {
                Map.new((
                  channel => $channel,
                  year    => .key,
                  months  => .value.sort(*.key).map: {
                     Map.new((
                        month       => .key,
                        human-month => @human-months[.key.substr(5,2)],
                        dates       => .value.map( -> $date {
                            my $log := $clog.log($date);
                            Map.new((
                              control      => $log.nr-control-entries,
                              conversation => $log.nr-conversation-entries,
                              day          => $date.substr(8,2).Int,
                              date         => $date,
                            ))
                        }).List
                     ))
                  },
                ))
            }

            render $html, $crot, {
              name             => $channel,
              channels         => @!channels,
              years            => @years,
              first-date       => @dates.head,
              first-human-date => human-date(@dates.head),
              last-date        => @dates.tail,
              last-human-date  => human-date(@dates.tail),
            }
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

    # Return content for searches
    method !search(
      :$channel!,
      :$nicks        = "",
      :$entries-pp   = 25,
      :$type         = "words",
      :$message-type = "",
      :$query,
      :$from-year,
      :$from-month,
      :$from-day,
      :$to-year,
      :$to-month,
      :$to-day,
      :$forward,
      :$ignorecase,
      :$all,
      :$include-aliases,
      :$json,      # return as JSON instead of HTML
    --> Str:D) {
        my $crot := $!templates-dir.add('search.crotmp');
        get-template-repository().refresh($crot.absolute)
          if $crot.modified > $!liftoff;
        my $clog := self.clog($channel);

        my %params;
        %params<all>        := True if $all;
        %params<ignorecase> := True if $ignorecase;
        %params<reverse>    := True unless $forward;

        %params{$message-type} := True if $message-type;

        my $from-date;
        if $from-year && $from-month && $from-day {
            $from-date = Date.new($from-year, $from-month, $from-day) // Nil;
        }
        my $to-date;
        if $to-year && $to-month && $to-day {
            $to-date = Date.new($to-year, $to-month, $to-day) // Nil;
        }
        if $from-date || $to-date {
            $from-date = $clog.dates.head.Date unless $from-date;
            $to-date   = $clog.dates.tail.Date unless $to-date;
            ($from-date, $to-date) = ($to-date, $from-date)
              if $to-date < $from-date;
            %params<dates> := $from-date .. $to-date;
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
                my %colors := $clog.colors;
                self!ready-entries-for-template(
                  $forward
                    ?? @found.head($fetch)
                    !! @found.head($fetch).reverse,
                  $channel,
                  $clog.colors,
                  :short
                )
            }
        }

        my $then    := now;
        my @entries  = find-em;
        my $elapsed := ((now - $then) * 1000).Int;
        my $first-date := @entries.head<date> // "";
        my $last-date  := @entries.tail<date> // "";
        my @years      := $clog.years;

        %params =
          all                => $all,
          control            => $message-type eq "control",
          conversation       => $message-type eq "conversation",
          channels           => @!channels,
          days               => 1..31,
          elapsed            => ((now - $then) * 1000).Int,
          entries            => @entries,
          entries-pp         => $entries-pp,
          entries-pp-options => <25 50 100 250 500>,
          first-date         => $first-date,
          first-human-date   => human-date($first-date),
          forward            => $forward,
          from-day           => $from-day,
          from-month         => $from-month,
          from-year          => $from-year || @years.head,
          ignorecase         => $ignorecase,
          include-aliases    => $include-aliases,
          last-date          => $last-date,
          last-human-date    => $last-date ?? human-date($last-date) !! "",
          months             => @template-months,
          more               => $more,
          name               => $channel,
          nicks              => $nicks,
          nr-entries         => +@entries,
          query              => $query || "",
          to-day             => $to-day,
          to-month           => $to-month,
          to-year            => $to-year || @years.tail,
          type               => $type,
          type-options       => (words       => "as word(s)",
                                 contains    => "containing",
                                 starts-with => "starting with",
                                 matches     => "as regex"
                                ),
          years              => @years,
        ;

        $json
          ?? to-json(%params,:!pretty)
          !! render-template($crot, %params)
    }

    proto method html(|) is implementation-detail {*}

    # Return an IO object for other HTML files in a channel
    multi method html($channel, $file --> IO:D) {
        my $template := $file.chop(5) ~ '.crotmp';

        my $dir  := $!html-dir.add($channel);
        my $html := $dir.add($file);
        my $crot := $!templates-dir.add($channel).add($template);
        $crot := $!templates-dir.add($template) unless $crot.e;

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
                render $html, $crot, {
                  :$channel,
                }
            }
            $html
        }
    }

    # Return an IO object for other HTML files in root dir
    multi method html($file --> IO:D) {
        my $template := $file.chop(5) ~ '.crotmp';

        my $html := $!html-dir.add($file);
        my $crot := $!templates-dir.add($template);

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
                render $html, $crot, {
                  channels => @!channels,
                }
            }
            $html
        }
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
            get -> 'search.html', :%args {
dd %args;
                content
                  'text/html',
                  self!search(|%args)
            }
            get -> 'search.json', :%args {
                content
                  'text/json',
                  self!search(:json, |%args)
            }

            get -> CHANNEL $channel {
                redirect "/$channel/index.html", :permanent
            }
            get -> CHANNEL $channel, 'index.html' {
                serve-static self!index($channel)
            }
            get -> CHANNEL $channel, 'search.html', :%args {
                content
                  'text/html; charset=UTF-8',
                  self!search(:$channel, |%args)
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
                my @dates = self.clog($channel).dates;
                redirect "/$channel/"
                  ~ (@dates[finds @dates, $year] || @dates.tail)
                  ~ '.html';
            }
            get -> CHANNEL $channel, MONTH $month {
                my @dates = self.clog($channel).dates;
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
dd "static";
                serve-static self.html($channel, $file);
            }
            get -> CHANNEL $channel, CSS $file {
                my $io := $!html-dir.add($channel).add($file);
                serve-static $io.e ?? $io !! $!html-dir.add($file)
            }
            get -> CHANNEL $channel, LOG $file {
                my $io := $!log-dir
                  .add($channel)
                  .add($file.substr(0,4))
                  .add($file.chop(4));

                serve-static $io
            }
            get -> HTML $file {
                serve-static self.html($file)
            }

            get -> $file {
                serve-static $!html-dir.add($file)
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

=end code

=head1 DESCRIPTION

App::IRC::Log is ...

=head1 AUTHOR

Elizabeth Mattijsen <liz@wenzperl.nl>

Source can be located at: https://github.com/lizmat/App-IRC-Log . Comments and
Pull Requests are welcome.

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

# vim: expandtab shiftwidth=4
