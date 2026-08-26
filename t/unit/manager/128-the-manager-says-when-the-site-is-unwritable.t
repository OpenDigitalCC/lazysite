#!/usr/bin/perl
# SM270: the manager says the site is unwritable on the next page load, instead
# of at the next failed save.
#
# Hestia's v-rebuild-web-domain re-applies its OWN docroot permissions - 2751:
# setgid, NO group write - and a rebuild driven through the control panel (an
# SSL renewal, an alias change, a panel upgrade) never reaches the lazysite
# deploy that repairs it. Ordering was fixed once and SM270 RECURRED three
# releases later for exactly that reason; the end-of-run repair helps only when
# lazysite RUNS. A stable-channel site taking no deploy for a month is
# unwritable for a month, and the changelog's own words for the symptom were
# "nothing notices until the manager fails to save".
#
# The engine cannot stop the panel. It can stop the condition being invisible,
# which is what this pins.
#
# THE STRUCTURAL CURE IS DIFFERENT AND IS DOCUMENTED, NOT TESTED HERE: a site on
# the SM142 per-site FastCGI pool runs as its OWN user, so owner-write suffices
# and Hestia's 2751 cannot break it. That is the fix; this is the safety net for
# every site not yet on it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $proc = "$root/lazysite-processor.pl";
plan skip_all => "no $proc" unless -f $proc;

my $src = do { open my $fh, '<', $proc or die $!; local $/; <$fh> };

# --- 1. the check exists and is arithmetic, not a probe ---------------------
my ($fn) = $src =~ /(sub _cgi_can_write \{.*?\n\})/s;
ok( $fn, 'the writability check is present' ) or do { done_testing(); exit };

unlike( $fn, qr/\s-w\s/,
    'it does not use -w, which answers for the real uid rather than for the '
        . 'identity being asked about' );
unlike( $fn, qr/open|mkdir|unlink/,
    'and does not probe by writing - a check that creates a file to find out '
        . 'whether it can is a check that can fail halfway' );

# --- 2. the arithmetic is right ---------------------------------------------
# Run the real sub against real directories rather than reasoning about modes.
{
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/yes"; mkdir "$d/no";
    chmod 0775, "$d/yes";
    chmod 0555, "$d/no";

    my $probe = "$d/probe.pl";
    open my $fh, '>', $probe or die $!;
    print {$fh} "$fn\nprint _cgi_can_write(\$ARGV[0]) ? 1 : 0;\n";
    close $fh;

    is( `$^X \Q$probe\E \Q$d/yes\E`, '1', 'a writable directory reads as writable' );
    is( `$^X \Q$probe\E \Q$d/no\E`,  '0', 'a read-only one does not' );

    # Cannot stat: not this check's finding to report. Guessing here would put a
    # scary banner on a manager page for an unrelated reason.
    is( `$^X \Q$probe\E \Q$d/absent\E`, '1',
        'an unstattable path is not reported as unwritable' );

    # THE PATH THAT ACTUALLY MATTERS IN THE FIELD, and the one the fixtures
    # above miss. A no-suexec CGI is www-data: it is NOT the owner and reaches
    # write through the GROUP. Both directories above are owned by the caller,
    # so the owner branch answers first and the group branch is never exercised
    # - a sabotage removing it entirely passed.
    #
    # 0570 is the shape: owner r-x (no write, so the owner branch must decline),
    # group rwx. If the group branch is right this is writable; if it is missing
    # or inverted, this reads unwritable and every site gets a false banner.
    SKIP: {
        my ($other) = grep { $_ != ( getpwuid $< )[3] } ( $) =~ /(\d+)/g );
        skip 'no secondary group to distinguish owner from group access', 1
            unless defined $other;
        mkdir "$d/grp";
        chown -1, $other, "$d/grp";
        chmod 0570, "$d/grp";
        is( `$^X \Q$probe\E \Q$d/grp\E`, '1',
            'writable through the GROUP counts - the case a www-data CGI is '
                . 'always in, and the one the owner-owned fixtures cannot show' );
    }
}

# --- 3. the banner is manager-only and says what to do ----------------------
{
    my ($blk) = $src =~ /(# SM270: say so the moment.*?\n    \}\n)/s;
    ok( $blk, 'the banner block is present' ) or do { done_testing(); exit };

    like( $blk, qr/\$layout eq \$MANAGER_LAYOUT/,
        'it runs on manager pages only - a public visitor pays nothing and '
            . 'learns nothing about the site being broken' );
    like( $blk, qr/lazysite repair/,
        'and names the one documented repair (SM624)' );
    like( $blk, qr/--domain/,
        'addressed by site, since that is what an operator holds' );
    like( $blk, qr/control-panel rebuild/,
        'and names the usual cause, so it is not read as a lazysite fault' );

    # The host goes into the page, so it must be sanitised - it is attacker-
    # controlled on any vhost that accepts an arbitrary Host header.
    like( $blk, qr/\$host =~ s/,
        'the Host header is filtered before being echoed into the banner' );
}

done_testing();
