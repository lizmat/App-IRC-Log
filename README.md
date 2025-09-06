[![Actions Status](https://github.com/lizmat/App-IRC-Log/actions/workflows/linux.yml/badge.svg)](https://github.com/lizmat/App-IRC-Log/actions) [![Actions Status](https://github.com/lizmat/App-IRC-Log/actions/workflows/macos.yml/badge.svg)](https://github.com/lizmat/App-IRC-Log/actions) [![Actions Status](https://github.com/lizmat/App-IRC-Log/actions/workflows/windows.yml/badge.svg)](https://github.com/lizmat/App-IRC-Log/actions)

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
  highlight-before   => "<strong>",
  highlight-after    => "</strong>",
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

The `App::IRC::Log` distribution provides an `App::IRC::Log` class for implementing an application to show IRC logs.

It is still heavily under development and may change its interface at any time.

It is currently being used at [the Raku IRC Logs server](https://irclogs.raku.org).

AUTHOR
======

Elizabeth Mattijsen <liz@raku.rocks>

Source can be located at: https://github.com/lizmat/App-IRC-Log . Comments and Pull Requests are welcome.

If you like this module, or what I'm doing more generally, committing to a [small sponsorship](https://github.com/sponsors/lizmat/) would mean a great deal to me!

COPYRIGHT AND LICENSE
=====================

Copyright 2021, 2022, 2025 Elizabeth Mattijsen

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

