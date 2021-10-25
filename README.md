[![Actions Status](https://github.com/lizmat/App-IRC-Log/workflows/test/badge.svg)](https://github.com/lizmat/App-IRC-Log/actions)

NAME
====

App::IRC::Log - Cro application for presenting IRC logs

SYNOPSIS
========

```raku
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
```

DESCRIPTION
===========

App::IRC::Log is a class for implementing an application to show IRC logs.

It is still heavily under development and may change its interface at any time.

It is currently being used to set up a website for showing the historical IRC logs of the development of the Raku Programming Language (see `App::Raku::Log`).

AUTHOR
======

Elizabeth Mattijsen <liz@raku.rocks>

Source can be located at: https://github.com/lizmat/App-IRC-Log . Comments and Pull Requests are welcome.

COPYRIGHT AND LICENSE
=====================

Copyright 2021 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

