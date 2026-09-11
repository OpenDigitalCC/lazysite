#!/usr/bin/perl
# plugins/remap.pl - the URL remapper extension (SM802).
#
# Per-domain prefix redirects for a site replacing another on the same hostname
# while links to the old one are still in the world - notifications, invoices,
# helpdesk tickets. Only when nothing else answers: a real page and an alias both
# win, so a rule can cover a link and never shadow content.
#
# A CONTRACT extension: it declares `contract`, so it is off until an operator
# switches it on, and switched off it does nothing at all - the render path reads
# the registry before it reads a rule (SM222 L0).
#
# The work lives in Lazysite::Remap. This file is the unit: what it is, what it
# owns, and the one report it offers.
use strict;
use warnings;
use JSON::PP qw(encode_json);

BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
exit run(@ARGV) if !caller;

sub describe {
    return {
        id          => 'remap',
        name        => 'URL remapper',
        description => 'Per-domain prefix redirects for a site that replaced '
            . 'another on the same hostname: /web and everything under it to a '
            . 'destination you name, path and query kept. Only when no page and '
            . 'no alias answers. Rules are written with remap-save (manage_domains); '
            . 'the destination always comes from the rules and never from the request, '
            . 'so this cannot become an open redirect. Each rule reports how often it '
            . 'was followed and when it was last used, read from the visitor log - '
            . 'when the last-used date stops moving, the rule can go.',
        contract => 1,
        owns     => {
            storage      => ['lazysite/remap/'],
            capabilities => [],
        },
        actions => [
            { id => 'report', label => 'Rules and use', run => 'action',
                note => 'Each rule with the number of times it was followed and '
                    . 'the last time, from the first-party visitor log.' },
        ],
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1               if $argv[$i] eq '--describe';
        $opt{docroot}  = $argv[ $i + 1 ] if $argv[$i] eq '--docroot';
        $opt{action}   = $argv[ $i + 1 ] if $argv[$i] eq '--action';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    my $docroot = $opt{docroot} // $ENV{DOCUMENT_ROOT} // '';
    require Lazysite::Paths;
    require Lazysite::Remap;
    my $lz = Lazysite::Paths::lazysite_dir($docroot);
    if ( ( $opt{action} // '' ) eq 'report' ) {
        print encode_json( Lazysite::Remap::report($lz) );
        return 0;
    }
    print encode_json( { ok => 0, error => 'usage: --describe | --action report --docroot DIR' } );
    return 0;
}

1;
