#!/usr/bin/perl

# SM289: set and read per-path access from a shell.
#
# WHY THIS EXISTS. Every other administrative act on lazysite has a CLI form,
# because the recovery story for this product is "you have a shell". Access
# control did not: an operator could create users and groups, set channels and
# policies, run the health check and repair permissions - and had no way to grant
# a person access to a path. So the answer to "the manager is locked out and I
# need to grant myself access" was to hand-edit acls.json, which is the exact
# thing SM267 was built to stop people doing.
#
# ONE WRITER, and that is the whole design. This calls
# Lazysite::Manager::Files::action_acl_set - the same function the manager panel,
# the control API and MCP call. A rule written from a shell is therefore the same
# object, governed by the same rules, moved into the private store by the same
# code (SM286), audited the same way. A fourth implementation of the ACL grammar
# would be a fourth place for it to drift.
#
# THE ACTOR IS MANDATORY, and this is the security-critical part of the file.
# Every other surface resolves an authenticated identity and applies the grant
# ceiling; there is no session behind a shell. Defaulting to an operator identity
# would turn a convenience into a privilege-escalation path on the one surface
# with nothing checking it - a user who cannot grant themselves access in the
# manager could simply run this instead. So --actor is required, its groups are
# resolved through the SAME resolver every channel uses (SM288), and the writer's
# own authority checks then apply unchanged.

use strict;
use warnings;
use FindBin ();
use lib "$FindBin::Bin/../lib";
use Getopt::Long ();
use JSON::PP     ();
BEGIN {
    # SM366: locate the Lazysite module tree relative to this script
    # (run-in-place, tarball and Hestia installs), falling back to the system
    # @INC (package installs). The same bootstrap lazysite-users.pl has always
    # carried; without it this tool cannot start anywhere the modules are not
    # already on @INC, which is every install that is not a package.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

use Lazysite::Manager::Files
    qw(action_acl_get action_acl_set action_acl_remove action_protected_sections);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl       ();
use Lazysite::Auth::Settings  ();
use Lazysite::Paths           ();

Getopt::Long::Configure( 'no_ignore_case', 'bundling_override' );

my $verb = shift @ARGV;
$verb = defined $verb ? $verb : '';

my %opt = ( docroot => '', actor => '', read => undef, write => undef,
    draft => undef, owner => undef, json => 0 );

Getopt::Long::GetOptions(
    'docroot=s' => \$opt{docroot},
    'actor=s'   => \$opt{actor},
    'read=s'    => \$opt{read},
    'write=s'   => \$opt{write},
    'owner=s'   => \$opt{owner},
    'draft!'    => \$opt{draft},
    'apply'     => \$opt{apply},
    'json'      => \$opt{json},
    'help|h'    => sub { usage(0) },
) or usage(2);

usage(0) if $verb eq 'help' || $verb =~ /\A-{0,2}help\z|\A-h\z/;
usage(2) unless length $verb;

fail('--docroot is required')          unless length $opt{docroot};
fail("not a directory: $opt{docroot}") unless -d $opt{docroot};

# SM139: lazysite never writes into a site tree as root. A write here touches
# acls.json AND MOVES CONTENT between two trees, creating directories in the
# private store as it goes - so running it as root leaves root-owned files where
# the CGI must be able to update them, which is the Class-B ownership drift
# SM215 exists to repair. save_acls now matches its directory's owner, but the
# store's directories are made by the move, so refusing is the right answer
# rather than a second safety net.
#
# Reads are allowed as root: they create nothing.
#
# LAZYSITE_CLI_FAKE_ROOT is the same test-only override lazysite-cli.pl uses, and
# like it, only ever makes this MORE restrictive.
if ( ( $> == 0 || $ENV{LAZYSITE_CLI_FAKE_ROOT} )
    && ( $verb eq 'set' || $verb eq 'remove' ) )
{
    fail( "refusing to change access as root.\n"
            . "  A write here creates files in the site tree, and root-owned files\n"
            . "  there are exactly what stops the manager working afterwards (SM139).\n"
            . "  Run it as the site user instead:\n"
            . "    sudo -u SITEUSER lazysite acl $verb ...\n"
            . "  (--actor is a different thing: it names the lazysite ACCOUNT the\n"
            . "  rule is written as, not the unix user running the command.)" );
}

# Context for the shared writer. Exactly what the CGI scripts set, and nothing
# more - if this list ever needs to grow, the writer has gained a dependency the
# other surfaces are also setting, and both should be looked at together.
my $docroot = $opt{docroot};
$docroot =~ s{/+\z}{};
$Lazysite::Manager::Files::DOCROOT = $docroot;
$Lazysite::Manager::Files::LOCK_DIR =
    Lazysite::Paths::lazysite_dir($docroot) . '/cache/locks';    # SM293
$Lazysite::Manager::Common::DOCROOT = $docroot;
$Lazysite::Auth::Acl::DOCROOT       = $docroot;

# A CLI caller is never a token client. token_auth suppresses the operator
# bypass, and setting it here would make --actor local behave differently from
# the same person in the manager - which is the opposite of the point.
$Lazysite::Auth::Acl::token_auth = 0;

my %HANDLER = (
    list          => \&cmd_list,
    show          => \&cmd_show,
    set           => \&cmd_set,
    remove        => \&cmd_remove,
    reapply       => \&cmd_reapply,
    'group-reach' => \&cmd_group_reach,
);
my $handler = $HANDLER{$verb} or do {
    print {*STDERR} "lazysite acl: unknown sub-command '$verb'\n\n";
    usage(2);
};
exit $handler->();

# ---------------------------------------------------------------------------

sub fail {
    print {*STDERR} "lazysite acl: $_[0]\n";
    exit 2;
}

# Resolve who is acting, and refuse rather than guess.
#
# Reads are actor-OPTIONAL, not actor-free. An unprotected path shows without
# one, which keeps the common "what governs this?" question cheap. A PROTECTED
# path does not: who may read a gated section is itself information about that
# section, and the shared reader refuses it for the same reason the manager
# does. cmd_show adds the hint, because "Not the owner of this file" is a true
# answer that does not tell a shell user the one thing they can do about it.
sub require_actor {
    my $actor = $opt{actor};
    fail( '--actor is required for a write. There is no session behind a '
            . 'shell, so this tool will not invent an identity: name the account '
            . 'the rule is being written AS, and it gets exactly the authority '
            . 'that account has in the manager.' )
        unless defined $actor && length $actor;

    # `local` is the documented always-operator identity. Allowed, because
    # break-glass recovery is the reason this tool exists - but only when asked
    # for by name. It is never a default.
    return $actor if $actor eq 'local';

    # No existence check here, deliberately. The auth store's users file is
    # parsed in exactly one place today (the users tool), and adding a second
    # parser to produce a friendlier error is the drift this whole programme has
    # been removing - a second reader of a store is a second thing to be wrong.
    #
    # An unknown actor resolves to no groups, is not an operator, and is refused
    # by the writer's own authority check. That is fail-closed and it is the same
    # answer the manager gives, which is the property that matters more than the
    # wording of the message.
    return $actor;
}

# Put the actor's identity where the shared writer reads it - the same three
# variables the CGI scripts set, with groups from the SAME resolver every
# channel uses (SM288), so "which groups is this account in" has one answer.
sub with_actor {
    my ( $actor, $code ) = @_;
    local $Lazysite::Manager::Files::auth_user = $actor;
    local $Lazysite::Auth::Acl::auth_user      = $actor;
    local @Lazysite::Auth::Acl::user_groups =
        ( $actor eq 'local' ? () : Lazysite::Auth::Acl::groups_for_user($actor) );
    return $code->();
}

sub emit {
    my ($r) = @_;
    if ( $opt{json} ) {
        print JSON::PP->new->canonical->pretty->encode($r);
        return $r->{ok} ? 0 : 1;
    }
    if ( !$r->{ok} ) {
        print {*STDERR} 'refused: ' . ( $r->{error} // 'unknown error' ) . "\n";
        return 1;
    }
    return 0;
}

# Warnings are printed on the human path too. The move into the private store
# can fail while the rule is still stored (SM286), and both outcomes look
# identical from outside - so a silent success here would be the same defect
# this whole programme is about.
sub say_warnings {
    my ($r) = @_;
    return unless ref $r->{warnings} eq 'ARRAY';
    print {*STDERR} "note: $_\n" for @{ $r->{warnings} };
    return;
}

sub subjects {
    my ($v) = @_;
    return undef unless defined $v;
    return [ grep { length } split /\s*,\s*/, $v ];
}

# SM288: WHICH @group ENTRIES REACH WHICH ACCOUNTS, resolved rather than named.
#
# SM288 made every channel honour an account's real groups. On MCP and the
# control API those @group entries had been silently inert, so the fix WIDENS
# effective access on live sites - intended, and still a change an operator is
# entitled to see before they meet it.
#
# lazysite-check names the entries and stops there, deliberately: it is
# core-Perl by design and resolving membership itself would be a fourth answer
# to "which groups is this account in", which is the defect SM288 removes.
# Reporting DIRECT membership only would be worse still - it would tell an
# operator that somebody does not gain access when they do.
#
# So the report lives here, where groups_for_user() - the one resolver every
# channel now uses - is already loaded. Nested groups are included because that
# function includes them; if it ever stops, this report is wrong in the same
# direction as the engine, which is the only safe way for it to be wrong.
sub cmd_group_reach {
    my $r = with_actor( ( $opt{actor} // 'local' ), sub {
            return action_protected_sections( $opt{actor} // 'local', [] );
    } );
    return emit($r) if !$r->{ok};

    # Every @group named by any entry, and the paths that name it.
    my %wanted;
    for my $s ( @{ $r->{sections} || [] } ) {
        my $path = $s->{site_wide} ? '/' : $s->{prefix};
        for my $mode (qw(read write)) {
            for my $e ( @{ $s->{$mode} || [] } ) {
                next unless defined $e && $e =~ /\A\@(.+)\z/;
                push @{ $wanted{ lc $1 } }, "$path ($mode)";
            }
        }
    }

    unless (%wanted) {
        print "No \@group entries in the ACL store.\n" unless $opt{json};
        return emit( { ok => 1, groups => {} } ) if $opt{json};
        return 0;
    }

    # THE ACCOUNT NAMES are read from the users file here; the GROUP RESOLUTION
    # is delegated. That distinction is the whole of SM288: a second reader of a
    # `user:hash` file is a trivial duplication, while a second answer to "which
    # groups is this account in" is the defect itself. groups_for_user() is the
    # one every channel now uses, nested groups included.
    my @accounts;
    my $users_file = Lazysite::Paths::lazysite_dir($docroot) . '/auth/users';
    if ( open my $uf, '<:utf8', $users_file ) {
        while ( my $l = <$uf> ) {
            chomp $l;
            $l =~ s/^\s+|\s+$//g;
            next if $l =~ /^#/ || !length $l;
            my ($u) = split /:/, $l, 2;
            push @accounts, $u if defined $u && length $u;
        }
        close $uf;
    }

    my %reach;
    for my $u ( sort @accounts ) {
        my %in = map { lc $_ => 1 } Lazysite::Auth::Acl::groups_for_user($u);
        for my $g ( keys %wanted ) {
            push @{ $reach{$g} }, $u if $in{$g};
        }
    }

    return emit( { ok => 1, groups => \%wanted, reach => \%reach } ) if $opt{json};

    for my $g ( sort keys %wanted ) {
        my @who = sort @{ $reach{$g} || [] };
        printf "\@%s\n", $g;
        printf "  grants: %s\n", join ', ', sort @{ $wanted{$g} };
        printf "  reaches: %s\n", ( @who ? join( ', ', @who ) : '(nobody)' );
    }
    print "\nThese apply on EVERY channel since SM288 - WebDAV, MCP and the\n";
    print "control API alike. On MCP and the control API they were silently\n";
    print "inert before, so any account listed above gained access at that\n";
    print "upgrade rather than losing it.\n";
    return 0;
}

sub cmd_list {
    my $r = with_actor( ( $opt{actor} // '' ), sub {
            return action_protected_sections( $opt{actor} // '', [] );
    } );
    return emit($r) if $opt{json} || !$r->{ok};

    my @s = @{ $r->{sections} || [] };
    unless (@s) {
        print "No protected sections.\n";
        return 0;
    }
    printf "%-34s %-7s %-6s %s\n", 'PATH', 'POLICY', 'PAGES', 'READ';
    for my $s (@s) {
        printf "%-34s %-7s %-6s %s\n",
            ( $s->{site_wide} ? '/ (whole site)' : $s->{prefix} ),
            $s->{policy}, $s->{pages},
            ( @{ $s->{read} || [] } ? join( ',', @{ $s->{read} } ) : '-' );
    }
    return 0;
}

sub cmd_show {
    my $path = shift @ARGV;
    fail('a PATH is required') unless defined $path && length $path;
    my $r = with_actor( ( $opt{actor} // '' ),
        sub { return action_acl_get( $path, $opt{actor} // '' ) } );

    # A refused read with no actor named is almost always the missing --actor,
    # not a real denial. Say so once, rather than leaving a shell user to
    # rediscover it.
    if ( !$r->{ok} && !length( $opt{actor} // '' ) && !$opt{json} ) {
        print {*STDERR} "refused: " . ( $r->{error} // '' ) . "\n";
        print {*STDERR}
            "hint: this path is protected, so reading its rule needs an "
            . "identity too - add --actor USER (or --actor local).\n";
        return 1;
    }
    return emit($r) if $opt{json} || !$r->{ok};

    my $a = $r->{acl};
    unless ( $a && %$a ) {
        print "$r->{path}: no rule - public\n";
        return 0;
    }
    print "$r->{path}\n";
    print '  owner:  ' . ( $a->{owner} // '-' ) . "\n";
    print '  read:   '
        . ( @{ $a->{read} || [] } ? join( ',', @{ $a->{read} } ) : '- (anyone)' ) . "\n";
    print '  write:  '
        . ( @{ $a->{write} || [] } ? join( ',', @{ $a->{write} } ) : '- (anyone)' ) . "\n";
    print '  policy: ' . ( $a->{draft} ? 'draft (404 to the public)' : 'gated' ) . "\n";
    return 0;
}

sub cmd_set {
    my $path  = shift @ARGV;
    my $actor = require_actor();
    fail('a PATH is required (use "/" for the whole site)')
        unless defined $path && length $path;
    fail('nothing to set - give at least one of --read, --write, --owner, --draft/--no-draft')
        unless defined $opt{read}
        || defined $opt{write}
        || defined $opt{owner}
        || defined $opt{draft};

    my $r = with_actor( $actor, sub {
            return action_acl_set( $path, $actor, subjects( $opt{read} ),
                subjects( $opt{write} ), $opt{owner},
                ( defined $opt{draft} ? ( $opt{draft} ? 'true' : 'false' ) : undef ) );
    } );
    say_warnings($r);
    my $rc = emit($r);
    print "set: $r->{path}\n" if !$rc && !$opt{json};
    return $rc;
}

# SM296 / SM286: re-apply every stored rule, so its content actually moves.
#
# THE PROBLEM THIS SOLVES, and it affects every site that protected anything
# before 0.10.9:
#
#   - protecting content moves it out of the document root, but ONLY on the act
#     of protecting (SM286, 0.10.8). A section protected on any earlier version
#     has its rule stored and honoured for pages while its FILES sit in the
#     served tree - measured on an upgraded site, 19 of 25 extensions were still
#     served byte-identically to an anonymous request;
#   - and on 0.10.8 specifically, the move could crash after the rule was saved
#     (SM296), leaving exactly the same state on a site that DID protect
#     something on that version.
#
# Both are repaired by the same action - re-issue each rule with its existing
# values, which runs the move - so this is one sweep rather than two migrations.
#
# It re-issues values that are ALREADY STORED. It grants nothing, revokes
# nothing and changes no rule; every path in the store ends with exactly the
# rule it started with. What changes is where the bytes are.
#
# Dry-run by default, like `lazysite migrate-engine-tree`: a sweep that moves
# content on a live site should be something the operator asked for twice.
sub cmd_reapply {
    my $actor = require_actor();

    my $listing = with_actor( $actor, sub {
            return action_protected_sections( $actor, [] );
    } );
    return emit($listing) if !$listing->{ok};

    my @sections = @{ $listing->{sections} || [] };
    unless (@sections) {
        print "No protected sections - nothing to re-apply.\n" unless $opt{json};
        return emit( { ok => 1, reapplied => [], count => 0 } ) if $opt{json};
        return 0;
    }

    unless ( $opt{apply} ) {
        printf "Would re-apply %d rule(s) on %s:\n", scalar @sections,
            $opt{docroot}
            unless $opt{json};
        print "  $_->{prefix}\n" for @sections;
        print "\nNothing has changed. Re-run with --apply to move the content.\n"
            unless $opt{json};
        return emit(
            { ok => 1,
                dry_run => 1,
                would   => [ map { $_->{prefix} } @sections ],
                count   => scalar @sections,
            }
        ) if $opt{json};
        return 0;
    }

    # SM529 follow-through: @already is content that needed no move, which is
    # success - it must not be counted with content that COULD NOT be moved.
    my ( @done, @failed, @unmoved, @already );
    for my $s (@sections) {
        my $path = $s->{site_wide} ? '/' : $s->{prefix};

        # Read the rule back and write the SAME values. Reading first matters:
        # passing undef for a list means "leave unchanged", which would be
        # enough to trigger the move - but it would also mean this tool's
        # behaviour depended on that subtlety staying true. Explicit is safer
        # for something that runs unattended across a fleet.
        my $cur = with_actor( $actor,
            sub { return action_acl_get( $path, $actor ) } );
        my $rule = ( $cur && $cur->{ok} ) ? ( $cur->{acl} || {} ) : {};

        my $r = with_actor( $actor, sub {
                return action_acl_set(
                    $path, $actor,
                    ( $rule->{read}  ? $rule->{read}  : undef ),
                    ( $rule->{write} ? $rule->{write} : undef ),
                    $rule->{owner},
                    ( defined $rule->{draft}
                        ? ( $rule->{draft} ? 'true' : 'false' )
                        : undef ),
                );
        } );

        # SM650: a half-applied rule now answers ok:0 / kind:partial, because
        # `ok` is the field every other caller reads. This tool already keyed on
        # content_move_failed and reported it correctly, so it is admitted here
        # rather than falling into the hard-failure branch below and losing the
        # reporting it has had since SM313.
        if ( $r && ( $r->{ok} || ( $r->{kind} // '' ) eq 'partial' ) ) {
            my @w = @{ $r->{warnings} || [] };

            # SM313: ok:1 is not success here.
            #
            # The whole purpose of this sweep is to MOVE content out of the
            # document root. A call that stored the rule and moved nothing has
            # done none of that, and it returns ok:1 with a warning - so the old
            # count reported "N re-applied, 0 failed" and exited 0 on a sweep
            # that left every byte exactly where it was. Measured in the field
            # on 2026-08-15: 11 of 11 entries still public afterwards.
            #
            # `content_moved` is a structural flag from action_acl_set rather
            # than a match on the warning text, so improving the wording cannot
            # quietly turn this back into a lie.
            # SM529 follow-through: key on the FAILURE flag, not on
            # content_moved => 0 - which since SM529 also means "nothing
            # needed moving" (already in the store, write-only, site-wide).
            # Counting those as unmoved made a second sweep of a correct site
            # report work it had not done and exit 1.
            if ( $r->{content_move_failed} ) {
                push @unmoved, { path => $path, warnings => \@w };
                unless ( $opt{json} ) {
                    print "NOT MOVED: $path\n";
                    print "  $_\n" for @w;
                }
            }
            elsif ( defined $r->{content_moved} && !$r->{content_moved} ) {
                push @already, { path => $path, warnings => \@w };
                unless ( $opt{json} ) {
                    print "already in place: $path\n";
                    print "  $_\n" for @w;
                }
            }
            else {
                push @done, { path => $path, warnings => \@w };
                unless ( $opt{json} ) {
                    print "re-applied: $path\n";
                    print "  WARNING: $_\n" for @w;
                }
            }
        }
        else {
            my $why = ( $r && $r->{error} ) ? $r->{error} : 'failed';
            push @failed, { path => $path, error => $why };
            print         {*STDERR} "FAILED: $path - $why\n" unless $opt{json};
        }
    }

    unless ( $opt{json} ) {
        printf "\n%d re-applied, %d already in place, %d could not be moved, "
            . "%d failed.\n",
            scalar @done, scalar @already, scalar @unmoved, scalar @failed;

        # SM313: name the cause ONCE, not per folder. A per-folder warning on a
        # fleet sweep reads as advisory noise and scrolls past; the operator
        # needs one sentence saying the sweep did not do its job and what to run.
        if (@unmoved) {
            print <<'WHY';

The rules are stored and the engine honours them, but the FILES are still in the
document root - so a front end serving them directly is not covered, which is
SM283. Every page and asset under those paths is still reachable anonymously.

This is almost always the private store: it is a SIBLING of the document root,
so it needs a directory the docroot repair does not touch. Repairing the docroot
alone does NOT fix it.

  lazysite check --docroot D              names the store, its owner and mode
  sudo lazysite check --docroot D --fix   creates it
  lazysite acl reapply --docroot D --apply --actor U    then re-run this

WHY
        }
        print "Verify from OUTSIDE with: lazysite check --check-acl URL\n"
            unless @failed || @unmoved;
    }
    return emit(
        { ok => ( ( @failed || @unmoved ) ? 0 : 1 ),
            reapplied => \@done,
            unmoved   => \@unmoved,
            already   => \@already,
            failed    => \@failed,
            count     => scalar @done,
        }
    ) if $opt{json};
    return ( @failed || @unmoved ) ? 1 : 0;
}

sub cmd_remove {
    my $path  = shift @ARGV;
    my $actor = require_actor();
    fail('a PATH is required') unless defined $path && length $path;

    my $r = with_actor( $actor,
        sub { return action_acl_remove( $path, $actor ) } );
    say_warnings($r);
    my $rc = emit($r);
    if ( !$rc && !$opt{json} ) {
        print $r->{removed}
            ? "removed: $r->{path}\n"
            : "no rule at $r->{path} - nothing to remove\n";
    }
    return $rc;
}

sub usage {
    my ($rc) = @_;
    my $fh = ( $rc // 0 ) == 0 ? *STDOUT : *STDERR;
    print {$fh} <<'USAGE';
Usage: lazysite acl SUBCOMMAND --docroot D [options] [PATH]

Read and set per-path access - the same rules, in the same store, as the
manager, the control API and MCP. A rule written here is identical to one
written there.

Sub-commands:
  list                      the sections currently held back
  show PATH                 the rule governing PATH, if any
  set  PATH --actor USER [--read LIST] [--write LIST] [--owner USER]
                         [--draft | --no-draft]
  remove PATH --actor USER
  reapply --actor USER [--apply]
                         re-issue every stored rule so its content moves out
                         of the document root. Repairs sections protected
                         before 0.10.9 (SM286) and any left half-moved by the
                         SM296 crash. Changes no rule - only where files live.
                         Dry-run unless --apply.

Options:
  --docroot D    the site's document root (required)
  --actor USER   the account the change is made AS (required for set/remove).
                 The rule is subject to exactly the authority that account has
                 in the manager. Use `local` for break-glass operator access.
  --read  LIST   comma-separated: usernames and @groups. Omit to leave
                 unchanged; an EMPTY list means anyone may read.
  --write LIST   likewise, for editing.
  --draft        hold the section back entirely: 404 to the public, and absent
                 from the sitemap, feeds and search. --no-draft clears it.
  --json         machine-readable output.

PATH is relative to the document root, NOT to a domain's URL - on a
content-rooted domain, /private/notes.pdf is `sites/foo/private`. Use "/" to
govern the whole site.

Setting a read list, or --draft, MOVES the content out of the document root
into the private store; removing the rule moves it back. The whole-site rule
is the exception and moves nothing.
USAGE
    exit( $rc // 0 );
}
