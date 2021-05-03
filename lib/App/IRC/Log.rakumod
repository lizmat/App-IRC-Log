use v6.*;

use Cro::HTTP::Router;
use Cro::WebApp::Template;
use IRC::Channel::Log;
use RandomColor;

subset HTML of Str where *.ends-with('.html');
subset CSS  of Str where *.ends-with('.css');
subset LOG  of Str where *.ends-with('.log');

my constant @months = <?
  January February March April May June July
  August September October November December
>;

# return Map with nicks mapped to HTML snippet with colorized nick
sub nicks2color(@nicks) {
    Map.new(( '','', @nicks.map: -> $nick {
        my $color := RandomColor.new(:luminosity<bright>).list.head;
        $nick => '<span style="color: ' ~ $color ~ '">' ~ $nick ~ '</span>'
    }))
}

# delimiters in message to find nicks
my constant @delimiters = ' ', '<', '>', |< : ; , + >;

class App::IRC::Log:ver<0.0.1>:auth<cpan:ELIZABETH> {
    has      $.log-class     is required is built(:bind);
    has IO() $.log-dir       is required;
    has IO() $.html-dir      is required;
    has IO() $.templates-dir is required;
    has      @.channels = $!log-dir.dir.map: *.basename;

    sub htmlize-message($entry, %color) {
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

                if $text.starts-with(".oO(") {
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

    method !day-file($channel, $date) {
        if try $date.Date -> $Date {
            my $dir := $!html-dir.add($channel).add($Date.year);
            my $io  := $dir.add($date ~ '.html');

            unless $io.e {
                my $log   := $!log-class.new(
                  $!log-dir.add($channel).add($Date.year).add($date)
                );
                my %color := nicks2color($log.nicks.keys);

                my @entries = $log.entries.map: {
                    Hash.new((
                      control      => .control,
                      conversation => .conversation,
                      hh-mm        => .hh-mm,
                      hour         => .hour,
                      message      =>  htmlize-message($_, %color),
                      minute       => .minute,
                      ordinal      => .ordinal,
                      target       => .target.substr(11),
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
                $io.spurt:
                  render-template $!templates-dir.add('day.crotmp'), {
                    :$channel,
                    :$date,
                    :date-human("$Date.day() @months[$Date.month] $Date.year()"),
                    :next-date($Date.later(:1day)),
                    :prev-date($Date.earlier(:1day)),
                    :@entries
                }
            }
            $io
        }
        else {
            Nil
        }
    }

    method application() {
        route {
            get -> $channel, HTML $file {
                my $io := self!day-file($channel, $file.substr(0,*-5));

                $io.e
                  ?? static $io.absolute
                  !! not-found
            }
            get -> $channel, CSS $file {
                my $io := $!html-dir.add($channel).add($file);
                $io.e
                  ?? static $io.absolute
                  !! ($io := $!html-dir.add($file)).e
                    ?? static $io.absolute
                    !! not-found
            }
            get -> $channel, LOG $file {
                my $io := $!log-dir
                  .add($channel)
                  .add($file.substr(0,4))
                  .add($file.substr(0,*-4));

                $io.e
                  ?? static $io.absolute, :mime-types({ '' => 'text/text' })
                  !! not-found
            }
            get -> $file {
                static $!html-dir, $file
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
