#!/usr/bin/perl
# lazysite-briefs.pl - SM245: briefs move out of band, into a store this
# plugin owns. The RECORD SM073 invented is worth keeping; the sidecar FILE
# is not - every rule the engine carried (serve-refusal, index-skip,
# listing metadata, move/copy carriage, private-store companionship) was a
# consequence of the storage choice, not of the feature. The store lives at
# lazysite/briefs/<content-path>, engine-owned and never served, and the
# engine no longer knows briefs exist.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);

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
        id          => 'briefs',
        name        => 'Briefs',
        description => 'Authoring briefs, out of band: the "why" record for '
            . 'a content file, held in an engine-owned store instead of a '
            . '.brief sidecar in the content tree. Read and append over the '
            . 'control API (brief-read / brief-append) and MCP (read_brief / '
            . 'append_brief). SM576: WRITING one needs manage_briefs, which '
            . 'this plugin declares; READING one is admitted by manage_briefs '
            . 'or manage_content, so a site that has always granted '
            . 'manage_content keeps the reads it had.',
        # SM469/ADR 0009: a contract plugin executes only while enabled, and
        # is born disabled - except that install/upgrade enables it for any
        # site that already has sidecars to migrate (SM245's back-compat
        # rule; a site that never used briefs loses nothing it used).
        contract => 1,

        # ADR 0009 / SM576 part 1: what this plugin OWNS, declared here and
        # nowhere else. `manage_briefs` is mirrored statically in @CAP_KEYS
        # because caps_for() runs on every request through every channel and
        # cannot afford a subprocess per plugin to discover it; t/lint/76 does
        # the discovering instead and fails if the two disagree. The plugin
        # stays the owner - a capability here that no plugin claims, or that
        # two claim, is what that lint refuses.
        owns          => { capabilities => ['manage_briefs'] },
        config_file   => 'lazysite/briefs.conf',
        config_schema => [
            { key => 'store_dir',
                label   => 'Where the brief store lives',
                type    => 'text',
                default => 'lazysite/briefs',
                note    => 'Engine-owned, never served. One entry per '
                    . 'content path, append-only.',
            },
        ],
        actions => [
            { id => 'status', label => 'Status', run => 'action' },
            { id => 'migrate', label => 'Migrate sidecars', run => 'action',
                note => 'Import every .brief sidecar into the store, then '
                    . 'remove the sidecar. Idempotent; never removes a '
                    . 'sidecar it did not import.' },
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
        $opt{status}   = 1               if $argv[$i] eq '--scan';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    my $docroot = $opt{docroot} // $ENV{DOCUMENT_ROOT} // '';
    my $act     = $opt{action}  // ( $opt{status} ? 'status' : '' );
    # SM557: the package is require'd at runtime, so this file mentions the
    # variable once by design - t/lint/04 refuses the 'used only once' warning.
    no warnings 'once';
    require Lazysite::Manager::Briefs;
    local $Lazysite::Manager::Briefs::DOCROOT = $docroot;
    if ( $act eq 'status' ) {
        print encode_json( Lazysite::Manager::Briefs::plugin_status() );
        return 0;
    }
    if ( $act eq 'migrate' ) {
        print encode_json( Lazysite::Manager::Briefs::action_briefs_migrate() );
        return 0;
    }
    print encode_json(
        { ok => 0, error => 'usage: --describe | --action status|migrate --docroot DIR' } );
    return 0;
}

1;
