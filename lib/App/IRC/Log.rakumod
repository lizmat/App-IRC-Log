use v6.*;

use Array::Sorted::Util;
use Cro::HTTP::Router;
use Cro::WebApp::Template;
use IRC::Channel::Log;
use RandomColor;

my constant %mime-types = Map.new((
  ''   => 'text/text',
  css  => 'text/css',
  html => 'text/html',
  ico  => 'image/x-icon',
));
my constant $default-mime-type = %mime-types{''};

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

sub gzip(IO:D $io) {
    my $gzip := $io.sibling($io.basename ~ '.gz');
    run('gzip', '--keep', '--force', $io.absolute)
      if !$gzip.e || $gzip.modified < $io.modified;
    $gzip
}

sub accept-encoding() {
    with request.headers.first: *.name eq 'Accept-Encoding' {
        .value
    }
    else {
        ''
    }
}

sub may-serve-gzip() {
    accept-encoding.contains('gzip')
}

sub render(IO:D $dir, IO:D $html, IO:D $crot, %_) {
    $dir.mkdir;
    $html.spurt:
    render-template $crot, %_;
    gzip($html);
}

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

subset HTML of Str  where *.ends-with('.html');
subset DAY  of HTML where { try .IO.basename.substr(0,10).Date }
subset CSS  of Str  where *.ends-with('.css');
subset LOG  of Str  where *.ends-with('.log');

my constant @months = <?
  January February March April May June July
  August September October November December
>;

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

# delimiters in message to find nicks
my constant @delimiters = ' ', '<', '>', |< : ; , + >;

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

class App::IRC::Log:ver<0.0.1>:auth<cpan:ELIZABETH> {
    has         $.log-class     is required is built(:bind);
    has IO()    $.log-dir       is required;
    has IO()    $.html-dir      is required;
    has IO()    $.templates-dir is required;
    has         &.htmlize     = &htmlize;
    has         &.nicks2color = &nicks2color;
    has Instant $.liftoff     = $?FILE.words.head.IO.modified;
    has         @.channels    = $!log-dir.dir.map({
                                    .basename if .d && !.basename.starts-with('.')
                                }).sort;

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
            my $log := $!log-class.new(
              $!log-dir.add($channel).add($Date.year).add($date)
            );
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
            render $dir, $html, $crot, {
              :$channel,
              :@!channels,
              :$date,
              :date-human("$Date.day() @months[$Date.month] $Date.year()"),
              :next-date($Date.later(:1day)),
              :prev-date($Date.earlier(:1day)),
              :@entries
            }
        }
        $html
    }

    # Return an IO object for other HTML files
    method !html($channel, $file --> IO:D) {
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
                render $dir, $html, $crot, {
                  :$channel,
                }
            }
            $html
        }
    }

    # Return the actual Cro application to be served
    method application() {
        subset CHANNEL of Str where { $_ (elem) @!channels }

        route {
            get -> CHANNEL $channel, DAY $file {
                serve-static self!day($channel, $file);
            }
            get -> CHANNEL $channel, HTML $file {
                serve-static self!html($channel, $file);
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
