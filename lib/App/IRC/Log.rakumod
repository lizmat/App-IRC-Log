use v6.*;

use Array::Sorted::Util;
use Cro::HTTP::Router;
use Cro::WebApp::Template;
use IRC::Channel::Log;
use RandomColor;

# Stopgap measure until we can ask Cro
my constant %mime-types = Map.new((
  ''   => 'text/text',
  css  => 'text/css',
  html => 'text/html',
  ico  => 'image/x-icon',
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
            static $io.absolute, |%_;
#    }
}
multi sub serve-static($, *%) { not-found }

# Subsets for routing
subset HTML of Str  where *.ends-with('.html');
subset CSS  of Str  where *.ends-with('.css');
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

# Hash for humanizing dates
my constant @human-months = <?
  January February March April May June July
  August September October November December
>;

# Turn a YYYY-MM-DD date into a human readable date
sub human-date(str $date) {
    $date.substr(8,2).Int
      ~ ' '
      ~ @human-months[$date.substr(5,2)]
      ~ ' '
      ~ $date.substr(0,4)
}

# Turn a YYYY-MM-DD date into a human readable month
sub human-month(str $date) {
    @human-months[$date.substr(5,2)]
      ~ ' '
      ~ $date.substr(0,4)
}

# Return Map with nicks mapped to HTML snippet with colorized nick
sub nicks2color(@nicks) {
    my str @seen  = '';
    my str @color = '';

    # Set up nicks with associated colors, using the same color for
    # nicks that are probably aliases (because they share the same
    # root)
    for @nicks.sort(-*.chars) -> $nick {
        my $pos   := finds @seen, $nick;
        my $found := @seen[$pos];

        inserts
          @seen,  $nick,
          @color, $found && $found.starts-with($nick)
            ?? @color[$pos]
            !! RandomColor.new(:luminosity<bright>).list.head;
     }

     # Turn the mapping into nick -> HTML mapping
     Map.new(( (^@seen).map: -> int $pos {
        if @color[$pos] -> $color {
            $_ => '<span style="color: '
                    ~ $color
                    ~ '">'
                    ~ $_
                    ~ '</span>'
            given @seen[$pos]
        }
        else {
            '' => ''
        }
    }))
}

# Delimiters in message to find nicks to highlight
my constant @delimiters = ' ', '<', '>', |< : ; , + >;

# Create HTML version of a given entry
sub htmlize($entry, %color) {
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
              { '<a href="' ~ $/~ '">' ~ $/ ~ '</a>' }
            );

            # Nick highlighting
            if $entry.^name.ends-with("Topic") {
                $text .= subst(/ ^ \S+ /, { %color{$/} // $/ });
            }
            else {
                $text = $text.split(@delimiters, :v).map(-> $word, $del = '' {
                    $word
                      ?? (%color{$word} // $word) ~ $del
                      !! $del
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
        $text .= subst(/^ \S+ /, { %color{$/} // $/ });

        if $entry.^name.ends-with("Nick-Change") {
            $text .= subst(/ \S+ $/, { %color{$/} // $/ });
        }
        elsif $entry.^name.ends-with("Kick") {
            $text .= subst(/ \S+ $/, { %color{$/} // $/ }, :5th)
        }
    }
    $text
}

#-------------------------------------------------------------------------------
# App::IRC::Log class
#
class App::IRC::Log:ver<0.0.1>:auth<cpan:ELIZABETH> {
    has         $.log-class     is required is built(:bind);
    has IO()    $.log-dir       is required;
    has IO()    $.html-dir      is required;
    has IO()    $.templates-dir is required;
    has         &.htmlize      is built(:bind) = &htmlize;
    has         &.nicks2color  is built(:bind) = &nicks2color;
    has Instant $.liftoff      is built(:bind) = $?FILE.words.head.IO.modified;
    has         %!channels;
    has         @.channels = $!log-dir.dir.map({
                                 .basename if .d && !.basename.starts-with('.')
                             }).sort;

    # Start loading the logs asynchronously
    method TWEAK() {
        %!channels{$_} := start {
            IRC::Channel::Log.new:
              logdir => $!log-dir.add($_),
              class  => $!log-class,
              name   => $_;
        } for @!channels;
    }

    # Return IRC::Channel::Log object for given channel
    method log(str $channel) {

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
                $_                               # ready, so go!
            }
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
            my $clog  := self.log($channel);
            my $log   := $clog.log($date);
            my %color := &!nicks2color($log.nicks.keys);

            # Set up entries for use in template
            my @entries = $log.entries.map: {
                Hash.new((
                  control      => .control,
                  conversation => .conversation,
                  hh-mm        => .hh-mm,
                  hour         => .hour,
                  message      =>  &!htmlize($_, %color),
                  minute       => .minute,
                  ordinal      => .ordinal,
                  target       => .target.substr(11),  # no need for Date
                  sender       =>  %color{.sender},
                ))
            }

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
                ?? "prev/$Date.earlier(:1month).first-date-in-month()"
                !! $date.substr(0,7)
              ),
              :prev-year($clog.is-first-date-of-year($date)
                ?? 'prev/' ~ Date.new($Date.year - 1, 1, 1)
                !! $date.substr(0,4)
              ),
              :@entries
            }
        }
        $html
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
                my @channels = @!channels.map: -> $channel {
                    my $log   := self.log($channel);
                    my @dates  = $log.dates.sort;  # XXX should be sorted
                    my %months = @dates.categorize: *.substr(0,7);
                    my @months = %months.sort(*.key).reverse.map: {
                        Map.new((
                          month       => .key,
                          human-month => human-month(.key),
                          dates       => .value.map( {
                              Map.new((
                                channel => $channel,
                                day     => .substr(8,2).Int,
                                date    => $_,
                              ))
                          }).List
                        ))
                    }
                    Map.new((
                      name             => $channel,
                      months           => @months,
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
    }

    # Return the actual Cro application to be served
    method application() {
        subset CHANNEL of Str where { $_ (elem) @!channels }

        route {
            get -> {
                redirect "/home.html", :permanent
            }

            get -> CHANNEL $channel {
                redirect "/$channel/index.html", :permanent
            }
            get -> CHANNEL $channel, 'today' {
                redirect "/$channel/"
                  ~ self.log($channel).this-date(now.Date.Str)
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'first' {
                redirect "/$channel/"
                  ~ self.log($channel).dates.head
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'last' {
                redirect "/$channel/"
                  ~ self.log($channel).dates.tail
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'random' {
                redirect "/$channel/"
                  ~ self.log($channel).dates.roll
                  ~ '.html';
            }

            get -> CHANNEL $channel, YEAR $year {
                my @dates = self.log($channel).dates.sort;  # XXX should be sorted already
                redirect "/$channel/"
                  ~ (@dates[finds @dates, $year] || @dates.tail)
                  ~ '.html';
            }
            get -> CHANNEL $channel, MONTH $month {
                my @dates = self.log($channel).dates.sort;  # XXX should be sorted already
                redirect "/$channel/"
                  ~ (@dates[finds @dates, $month] || @dates.tail)
                  ~ '.html';
            }

            get -> CHANNEL $channel, 'prev', DATE $date {
                with self.log($channel).prev-date($date) -> $prev {
                    redirect "/$channel/$prev.html", :permanent
                }
                else {
                    redirect "/$channel/$date.html"
                }
            }
            get -> CHANNEL $channel, 'this', DATE $date {
                redirect "/$channel/"
                  ~ self.log($channel).this-date($date.Str)
                  ~ '.html';
            }
            get -> CHANNEL $channel, 'next', DATE $date {
                with self.log($channel).next-date($date) -> $next {
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
            get -> CHANNEL $channel, CSS $file {
                my $io := $!html-dir.add($channel).add($file);
                serve-static $io.e ?? $io !! $!html-dir.add($file)
            }
            get -> CHANNEL $channel, LOG $file {
                my $io := $!log-dir
                  .add($channel)
                  .add($file.substr(0,4))
                  .add($file.chop(4));

                serve-static $io, :%mime-types
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
