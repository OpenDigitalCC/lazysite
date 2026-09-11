#!/usr/bin/perl
# SM832: plugin-list's `id` is a key plugin-read accepts.
#
# Reported from the field (1311E-06): plugin-list returned
# {"id": "bad-url-blocker", "_script": "plugins/bad-url-blocker.pl"}, and
# plugin-read&plugin=bad-url-blocker answered "no plugin 'bad-url-blocker' is
# installed - call plugin-list for the ids this site has". A caller who did
# exactly what the error said arrived back where they started.
#
# SM809 had already made the `plugin` parameter reach the resolver. What it did
# not do was map an id to a script: the registry is keyed by path.
#
# NOT BY FILENAME, and this file runs against the REAL shipped plugins because
# that is where the convention breaks. Twelve of fourteen publish their filename
# stem as their id; audit.pl publishes `link-audit` and log.pl publishes
# `logging`. A stem rule passes on bad-url-blocker and fails silently on those
# two - so they are asserted by name.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Manager::Plugins ();

my $root = repo_root();
plan skip_all => 'no plugins/ in this tree' unless -d "$root/plugins";

# plugin_registry scans realpath("$DOCROOT/..")/plugins, so point DOCROOT one
# level below the repository root and it finds the shipped plugins directly.
$Lazysite::Manager::Plugins::DOCROOT = "$root/starter";

sub resolve {
    my ( $id, $script ) = @_;
    my ( $full, $why ) = Lazysite::Manager::Plugins::_resolve_plugin_or_why( $id, $script );
    return ( $full ? ( $full =~ s{\A\Q$root\E/}{}r ) : undef, $why );
}

# --- THE CANARY -------------------------------------------------------------
{
    my ($got) = resolve( undef, 'plugins/bad-url-blocker.pl' );
    is( $got, 'plugins/bad-url-blocker.pl', 'the script path resolves, as it always did' );
}

# --- THE FINDING ------------------------------------------------------------
{
    my ($got) = resolve( 'bad-url-blocker', undef );
    is( $got, 'plugins/bad-url-blocker.pl',
        "the listing's `id` resolves to its script" );
}

# --- WHERE A FILENAME RULE WOULD HAVE FAILED --------------------------------
{
    my ($got) = resolve( 'link-audit', undef );
    is( $got, 'plugins/audit.pl', "an id that is not its filename still resolves (link-audit)" );
}
{
    my ($got) = resolve( 'logging', undef );
    is( $got, 'plugins/log.pl', "...and so does the other one (logging)" );
}

# --- THE BODY ROUTE (SM839) --------------------------------------------------
# plugin-save names its target in the body's `script` key. SM832 resolved an id
# only for the `plugin` parameter, so {"script": "link-audit"} was refused - and
# the refusal told the caller to pass the id. Both exceptions, on that route.
{
    my ($got) = resolve( undef, 'link-audit' );
    is( $got, 'plugins/audit.pl', 'an id in the body script key resolves (link-audit)' );
}
{
    my ($got) = resolve( undef, 'logging' );
    is( $got, 'plugins/log.pl', '...and the other exception (logging)' );
}
{
    my ( $got ) = resolve( undef, 'audit' );
    is( $got, undef, 'a filename stem that is nobody\'s id is refused on this route too' );
}

# The STEM of a plugin whose id differs is not that plugin's id, and resolving it
# would make "id" mean two things. The guess is confirmed against the declared id,
# so it is refused rather than accepted by accident.
{
    my ( $got, $why ) = resolve( 'audit', undef );
    is( $got, undef, "a filename stem that is not anybody's id is not accepted as one" );
}

# --- THE REFUSAL NAMES THE FIELD --------------------------------------------
{
    my ( $got, $why ) = resolve( 'no-such-plugin', undef );
    is( $got, undef, 'an unknown id is refused' );
    like( $why, qr/`id`/,      'the refusal says which listing field to pass' );
    like( $why, qr/`_script`/, '...or the other one' );
    unlike( $why, qr/for the ids this site has\z/,
        'rather than pointing back at the listing and nothing more' );
}

done_testing();
