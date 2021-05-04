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

sub serve-static(IO:D $io is copy, |c) {
dd $io.absolute;
    if $io.e {
#        if may-serve-gzip() {
#dd "serving zipped";
#            header 'Transfer-Encoding', 'gzip';
#            static gzip($io).absolute, |c, :mime-types({ 'gz' => mime-type($io) });
#            content mime-type($io), gzip($io).slurp(:bin);
#        }
#        else {
            static $io.absolute, |c;
#        }
    }
    else {
        not-found;
    }
}

subset HTML of Str  where *.ends-with('.html');
subset DAY  of HTML where try *.IO.basename.substr(0,10).Date;
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

    if $entry.conversation {
        if $text.starts-with("m: ") {
            $text = $text.substr(0,3)
              ~ '<div id="code">'
              ~ $text.substr(3)
              ~ '</div>';
        }

        else {
            $text .= subst(
              / https? '://' \S+ /,
              { '<a href="' ~ $/~ '">' ~ $/ ~ '</a>' }
            );

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

            if $entry.^name.ends-with("Self-Reference")
              || $text.starts-with(".oO(") {
                $text = '<div id="thought">' ~ $text ~ '</div>'
            }
        }
    }
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

    method !day($channel, $date) {
        if try $date.Date -> $Date {
            my $dir  := $!html-dir.add($channel).add($Date.year);
            my $html := $dir.add($date ~ '.html');
            my $crot := $!templates-dir.add('day.crotmp');

            if !$html.e                           # file does not exist
              || $html.modified < $!liftoff       # file is too old
                                | $crot.modified  # template changed
            {
                my $log   := $!log-class.new(
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

                $dir.mkdir;
                $html.spurt:
                  render-template $crot, {
                    :$channel,
                    :@!channels,
                    :$date,
                    :date-human("$Date.day() @months[$Date.month] $Date.year()"),
                    :next-date($Date.later(:1day)),
                    :prev-date($Date.earlier(:1day)),
                    :@entries
                }
                gzip($html);
            }
            $html
        }
        else {
            Nil
        }
    }

    method application() {
        route {
            get -> $channel, DAY $file {
                serve-static self!day($channel, $file.substr(0,*-5));
            }
            get -> $channel, CSS $file {
                my $io := $!html-dir.add($channel).add($file);
                serve-static $io.e ?? $io !! $!html-dir.add($file)
            }
            get -> $channel, LOG $file {
                my $io := $!log-dir
                  .add($channel)
                  .add($file.substr(0,4))
                  .add($file.substr(0,*-4));

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
