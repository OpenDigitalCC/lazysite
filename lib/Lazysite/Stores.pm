package Lazysite::Stores;

# SM770: THE CATALOGUE OF WHAT LIVES UNDER lazysite/, AND WHICH OF IT IS A
# STORE.
#
# SM766 made the rule - a store reader never turns an unopenable file into an
# empty answer - and t/lint/121 held it for the two directories that had just
# been caught breaking it. Then 0.13.5 added `lazysite/connectors/`, the lint
# did not know about it, and the field found the same fault there within a day
# of the release (SM768): `has_secret: 0` for a secret that was merely
# unreadable. A lint that NAMES the stores it protects protects the stores
# somebody remembered.
#
# So the list moves here, in front of the lint, and gains the other half: every
# directory the engine uses under lazysite/ must be CLASSIFIED. A new one is a
# lint failure until somebody says which it is - a store whose readers obey the
# rule, or not a store, with the reason written down. Forgetting is no longer
# the default outcome; declaring is.
#
# WHAT MAKES SOMETHING A STORE. It holds state the engine is authoritative
# about, where "the file would not open" and "the file says nothing" are
# different answers to an operator. A cache is not a store: an unreadable cache
# entry IS an empty one, because the answer is rebuilt from the thing it caches.
# Rendered output is not a store for the same reason.
#
# WHAT THE RULE REQUIRES of a store's readers:
#   1. every read-open whose failure branch returns routes through
#      Lazysite::Util::cannot_read, which WARNs with the file, the error and
#      the unix user - unless the file is simply absent (ENOENT), which is an
#      ordinary state and says nothing;
#   2. no `-f`/`-e` guard in front of that open. A stat the process is not
#      allowed to make fails the same way as an open it is not allowed to make,
#      and the guard renders that as absence BEFORE the open can report it.
#      Where a reader caches on the file's identity, the stat serves the cache
#      key and never the absence decision.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(stores store_dirs store_for is_store);

# dir      - the directory under lazysite/
# store    - 1 when its readers must obey the rule above
# why      - for a non-store, why the rule does not apply (read by a person)
# modules  - the files whose read-opens the lint checks. Listed rather than
#            inferred because a reader reaches its store through a helper
#            (_auth_dir(), $AUTH_DIR, _dir()) far more often than it names the
#            path; the lint checks the other direction too, so a module that
#            mentions a store and is not listed here is reported.
my @STORES = (
    { dir => 'auth',
        store   => 1,
        modules => [
            'lib/Lazysite/Auth/Acl.pm',   'lib/Lazysite/Auth/DomainAccess.pm',
            'lib/Lazysite/Auth/OAuth.pm', 'lib/Lazysite/Auth/Session.pm',
            'lib/Lazysite/Auth/Settings.pm',

            # SM685: the credential path moved here out of the tool, taking
            # read_users and read_groups with it. Listed for the reason the
            # note below gives about the tool - a reader the catalogue does not
            # name is a reader lint 121 never looks at.
            'lib/Lazysite/Auth/Verify.pm',

            # SM800: THE TOOL THAT OWNS THE STORE. It was not listed, so lint
            # 121 - which exists to catch a stat guard in front of a store read
            # - had never been pointed at the file that WRITES this store and
            # holds its two primary readers. Both of them still carried the
            # guard SM770 removed from the modules above: `return %users unless
            # -f $USERS_FILE`, so an auth directory without its search bit
            # answered "no accounts", in silence, to `users list` and to
            # everything downstream of read_groups.
            #
            # The lesson for the catalogue, and the reason this comment is
            # here: "the modules that read a store" is not the same list as
            # "the modules under lib/". A tool is a reader.
            'tools/lazysite-users.pl',

            # SM917 step 3: SEVEN OTHER FILES READ THIS STORE AND ARE NOT LISTED,
            # DELIBERATELY - lazysite-manager-api.pl, lazysite-processor.pl,
            # Capabilities.pm, Daemon/Service/Scheduler.pm, DomainRewrites.pm,
            # Git.pm and Manager/Common.pm. They are covered by t/lint/121's
            # literal-path check instead, and listing them here was tried and
            # withdrawn the same day.
            #
            # WHY, measured: this list is a per-FILE proxy for a per-PATH rule.
            # For a small module that is exact, because nearly every read-open in
            # it is a store read. Adding lazysite-processor.pl put SIXTY-ONE
            # read-opens under the rule, of which ONE was an auth read and
            # twenty-three were markdown, template and theme reads that are no
            # store's business. Satisfying that needs ~38 `# not a store` markers
            # in the render path, and a marker that appears everywhere stops being
            # a signal and becomes furniture.
            #
            # So the two checks divide the job by what each can actually see: the
            # literal check catches a read that NAMES a store, in any file; this
            # list catches a read that reaches its store through a helper, where
            # no literal exists to match. Connectors.pm is the case that proves
            # the list is still needed - it never writes its own path.
        ],
    },
    { dir => 'daemon',
        store   => 1,
        modules => [
            'lib/Lazysite/Daemon/Supervisor.pm',
            'lib/Lazysite/Daemon/Service/Scheduler.pm',

            # SM842: the schedule's own run record (schedule-runs.json) - when
            # each entry last ran, so an unreadable one must not read as "never".
            'lib/Lazysite/Daemon/Jobs.pm',
        ],
    },
    { dir => 'connectors',
        store   => 1,
        modules => ['lib/Lazysite/Manager/Connectors.pm'],
    },

    # SM842: A STORE NOW. It was classified as configuration the dispatcher
    # reports on - true, and not enough: handlers.conf is read-modify-written
    # by every surface that saves a handler, and a save over a file that could
    # not be read would have replaced every handler with one (SM785's shape).
    # Lazysite::Handlers is the one reader and writer of handlers.conf,
    # schedule.conf and the form bindings.
    { dir => 'forms',
        store   => 1,
        modules => ['lib/Lazysite/Handlers.pm'],
    },

    # NOT STORES. Each line is an argument, not a label.
    { dir => 'cache',
        store => 0,
        why   => 'a cache: an entry that will not open is an entry that is not there, '
            . 'because the answer is rebuilt from what it caches',
    },
    # SM907: A STORE NOW, and the entry it replaces was the argument the field
    # disproved. It read: "append-only records. A reader that cannot open one
    # shows an empty page, and the writer says so in its own log." Both halves
    # were true and the conclusion was wrong. The writer does say so - through
    # log_event, which prints to standard error, which for a CGI is the web
    # server's error log, which is not a place an operator looks. And the empty
    # page is the whole problem: a site whose trail held six events it could
    # read and could not append to rendered a short, healthy-looking list, and
    # the operator had to ASK why an agent's work left no trace.
    #
    # The trail is the one record a sysop is meant to be able to trust, so
    # "would not open" and "says nothing" are further apart here than anywhere
    # else under lazysite/.
    #
    # SM907 AT6: stats.pl is listed because IT READS LOGS, not because the logs it
    # reads live here - the visitor log is the web server's own access log, found
    # by auto-detection or LAZYSITE_ACCESS_LOG, and the form-event log sits under
    # lazysite/stats. The rule belongs to a log reader wherever the log is, and
    # listing the module is how lint 121 reaches it.
    #
    # MEASURED, and the filing's premise was too broad: the MAIN access-log read
    # already refuses correctly - "An access log exists for this site but is not
    # readable by the web server user" - so the headline count was never the lie.
    # The secondary readers were: a log tail, the rotated log files and the
    # form-event files each skipped in silence, which shortens counts without
    # saying so. Those report now, and the export names which logs would not open.
    #
    # stats.pl loads no Lazysite modules by design - it runs as a subprocess - so
    # it carries its own reporter in the same shape.
    # SM485 adds Notify as a third reader: it counts its own hourly sends out of
    # logs/notice-mail.jsonl, and an unreadable record there returns undef rather
    # than 0 - "could not tell" is the state a cap must refuse on, never the one
    # it treats as room to send.
    # SM918 adds Notices as a fourth reader, and it is the one the CGIs now call:
    # the notice store's reader moved out of lazysite-manager-api.pl so that
    # lazysite-mcp.pl reads it through the same code rather than a second copy.
    # The move carried the four-state repair - the old reader made an unopenable
    # store an empty bell, in the `if ( open ... )` form t/lint/121 cannot see.
    { dir => 'logs',
        store   => 1,
        modules => [ 'lazysite-manager-api.pl', 'plugins/stats.pl', 'lib/Lazysite/Notify.pm',
            'lib/Lazysite/Manager/Notices.pm' ],
    },
    { dir => 'backups',
        store => 0,
        why => 'archives, addressed by name and verified by digest; the listing reports '
            . 'what it can stat and a snapshot that will not open fails its restore loudly',
    },
    { dir => 'db',
        store => 0,
        why => 'SQLite owns the file; a store it cannot open is a DBI error carried to the '
            . 'caller, never an empty result set (Lazysite::Data::Connect)',
    },
    { dir => 'briefs',
        store => 0,
        why   => 'authored content in the content tree, not engine state',
    },
    { dir => 'git',
        store => 0,
        why   => 'the content-history repository; git reports its own faults and the '
            . 'COMMIT_FAILED breadcrumb surfaces them in Status',
    },
    { dir => 'layouts',
        store => 0,
        why => 'installed layouts and themes - content, and a theme that will not load is '
            . 'a render failure the page reports',
    },
    { dir => 'nav',
        store => 0,
        why   => 'generated navigation, rebuilt from the content tree',
    },
    { dir => 'aliases',
        store => 0,
        why => 'redirect rules, rebuilt on demand and reported empty by the manager page',
    },
    { dir => 'themes',
        store => 0,
        why => 'theme pristine copies, addressed by name; an unreadable one fails its copy',
    },
    { dir => 'manager',
        store => 0,
        why   => 'the manager pages themselves - content served to a browser',
    },
    { dir => 'brands',
        store => 0,
        why   => 'brand packs - assets an author installs, served like any other content',
    },
    { dir => 'feedback',
        store => 0,
        why => 'agent feedback files, addressed by name and listed for the operator; a file '
            . 'that will not open is one the listing cannot show, not a fact about the site',
    },
    { dir => 'notify-templates',
        store => 0,
        why   => 'notification bodies. A template that will not open falls back to the '
            . 'built-in body, which is the designed behaviour rather than a silent empty',
    },
    { dir => 'templates',
        store => 0,
        why   => 'page templates - content the processor renders from',
    },
    { dir => 'i18n',
        store => 0,
        why   => 'translation tables; a missing string falls back to the source language',
    },
);

sub stores     { return @STORES }
sub store_dirs { return map { $_->{dir} } @STORES }

sub store_for {
    my ($dir) = @_;
    return unless defined $dir;
    my ($s) = grep { $_->{dir} eq $dir } @STORES;
    return $s;
}

sub is_store {
    my ($dir) = @_;
    my $s = store_for($dir) or return 0;
    return $s->{store} ? 1 : 0;
}

1;
