#!/usr/bin/perl
# SM1369 X7, part one (ruling 135): CORE'S LIB HOLDS NO EXTENSION'S MODULE, AND
# CORE REACHES ONE ONLY THROUGH THE EXTENSION'S PAYLOAD LIB.
#
# A hook (X2 onwards) may name only a module in the extension's own payload lib,
# found nowhere else on @INC (Lazysite::Extensions::Hooks, C-3), so Odoo's modules
# left core's lib/ for extensions/odoo/lib before X2. This holds both halves:
#
#   1. CORE'S lib/ HOLDS NONE OF THEM. No file under lib/ is a module an in-tree
#      extension's payload lib holds, and none is in Odoo's namespaces
#      (Lazysite::Odoo, Lazysite::Odoo::*, the two Odoo services). A module put
#      back in lib/ would shadow the payload's copy, and a hook on it is refused.
#   2. CORE LOADS ONE ONLY BY THE RULE. A core file (lint 321's set: the CGIs and
#      install.pl, the processor's parts, the library, the tools) that names a
#      payload module in a `use` or `require` fails: it must reach it through
#      Lazysite::Extensions::require_payload (or the processor's _lazy_lib, which
#      falls back to it), which loads the engine's own copy from the payload lib
#      beside core's and refuses a stale copy anywhere else. A bare `require`
#      would load whichever copy @INC finds first, and in a deployed CGI that is
#      none: the payload lib is not on @INC until the rule puts it there.
#   3. The rule itself: in a fresh perl with only core's lib, require_payload
#      loads a module from the payload lib and nowhere else.
#
# An extension's own files (its descriptor, the endpoints it declares, its payload)
# load its modules as they like: they are not core.
#
# Sabotage: `git mv extensions/odoo/lib/Lazysite/Odoo/Name.pm lib/Lazysite/Odoo/`
# fails the first half; `require Lazysite::Odoo;` in lib/Lazysite/Validate.pm fails
# the second.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_child);

my $root = repo_root();

# ---- the payload modules ----
my %payload;    # Lazysite/Odoo.pm => extensions/odoo/lib
for my $lib ( sort glob("$root/extensions/*/lib") ) {
    ( my $rel_lib = $lib ) =~ s{\A\Q$root\E/}{};
    find( { no_chdir => 1, wanted => sub {
                return unless -f && /\.pm\z/;
                ( my $rel = $File::Find::name ) =~ s{\A\Q$lib\E/}{};
                $payload{$rel} = $rel_lib;
            } }, $lib );
}
ok( $payload{'Lazysite/Odoo.pm'}, "Odoo's engine is in its payload lib ($payload{'Lazysite/Odoo.pm'})" );
ok( $payload{'Lazysite/Daemon/Service/Oomd.pm'} && $payload{'Lazysite/Daemon/Service/OdooEndpoint.pm'},
    'and its two daemon services' );
cmp_ok( scalar keys %payload, '>=', 15, 'the payload modules were found (' . scalar( keys %payload ) . ')' );

# ---- 1. core's lib holds none ----
my @in_core;
find( { no_chdir => 1, wanted => sub {
            return unless -f && /\.pm\z/;
            ( my $rel = $File::Find::name ) =~ s{\A\Q$root\E/lib/}{};
            push @in_core, "lib/$rel (also $payload{$rel}/$rel)" if $payload{$rel};
            push @in_core, "lib/$rel (Odoo's namespace)"
                if !$payload{$rel} && $rel =~ m{\ALazysite/(?:Odoo(?:\.pm\z|/)|Daemon/Service/O(?:omd|doo))};
        } }, "$root/lib" );
is_deeply( \@in_core, [], "core's lib/ holds no extension module" )
    or diag( join( "\n", @in_core ) . "\n\nAn extension's module lives in its payload lib (extensions/<id>/lib), "
        . 'never in core\'s lib (SM1369, ruling 135).' );

# ---- 2. core loads one only by the rule ----
my %mod_of = map { ( my $m = $_ ) =~ s{/}{::}g; $m =~ s/\.pm\z//; ( $m => $_ ) } keys %payload;

my %own;    # an extension's endpoints are its own
for my $d ( glob("$root/extensions/*.pl") ) {
    open my $fh, '<', $d or die "$d: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    if ( $src =~ /\bendpoints\s*=>\s*\[([^\]]*)\]/ ) { $own{$_} = 1 for $1 =~ /'([a-z][a-z0-9-]*\.pl)'/g }
}
ok( $own{'lazysite-odoo.pl'}, "the Odoo endpoint is the extension's own" );

my @core = grep { -f && !$own{ s{\A\Q$root\E/}{}r } } glob("$root/*.pl");
push @core, glob("$root/lazysite-processor/*.pm"), glob("$root/tools/*.pl");
find( { no_chdir => 1, wanted => sub { push @core, $File::Find::name if -f && /\.pm\z/ } }, "$root/lib" );
cmp_ok( scalar @core, '>', 150, 'the core files were found (' . scalar(@core) . ')' );

my @bare;
for my $f ( sort @core ) {
    ( my $rel = $f ) =~ s{\A\Q$root\E/}{};
    open my $fh, '<', $f or die "$f: $!";
    my ( $n, $pod ) = ( 0, 0 );
    while ( my $l = <$fh> ) {
        $n++;
        last if $l =~ /\A__(?:END|DATA)__\b/;
        if ( $l =~ /\A=(\w+)/ ) { $pod = $1 ne 'cut'; next }
        next if $pod || $l =~ /\A\s*#/;
        while ( $l =~ /\b(?:use|require)\s+([A-Z]\w*(?:::\w+)*)/g ) {
            push @bare, "$rel:$n: $1" if $mod_of{$1};
        }
        while ( $l =~ /-M([A-Z]\w*(?:::\w+)*)/g ) {
            push @bare, "$rel:$n: -M$1" if $mod_of{$1};
        }
    }
    close $fh;
}
is_deeply( \@bare, [], 'no core file loads a payload module but through the rule' )
    or diag( join( "\n", @bare ) . "\n\nReach it with Lazysite::Extensions::require_payload('Module::Name') "
        . '(the processor: _lazy_lib), which loads the engine\'s own copy from the payload lib.' );

# ---- 3. the rule, in a fresh perl with only core's lib ----
{
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $code = 'use Lazysite::Extensions; Lazysite::Extensions::require_payload("Lazysite::Odoo::Name"); '
        . 'print $INC{"Lazysite/Odoo/Name.pm"}, "\n"; print( ( grep { m{/extensions/odoo/lib\z} } @INC ) ? "on" : "off", "\n" )';
    my $r = run_child( [ $^X, "-I$root/lib", '-e', $code ] );
    my ( $where, $inc ) = split /\n/, $r->{out} // '';
    is( $where, "$root/extensions/odoo/lib/Lazysite/Odoo/Name.pm", 'require_payload loads it from the payload lib' )
        or diag( $r->{err} );
    is( $inc, 'on', 'which it put on @INC' );

    my $none = run_child( [ $^X, "-I$root/lib", '-e', 'require Lazysite::Odoo::Name; print "loaded\n"' ] );
    unlike( $none->{out} // '', qr/loaded/, 'and a bare require, with core\'s lib alone, finds nothing' );
}

done_testing();
