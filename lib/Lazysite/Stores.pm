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
        ],
    },
    { dir => 'daemon',
        store   => 1,
        modules => [
            'lib/Lazysite/Daemon/Supervisor.pm',
            'lib/Lazysite/Daemon/Service/Scheduler.pm',
        ],
    },
    { dir => 'connectors',
        store   => 1,
        modules => ['lib/Lazysite/Manager/Connectors.pm'],
    },

    # NOT STORES. Each line is an argument, not a label.
    { dir => 'cache',
        store => 0,
        why   => 'a cache: an entry that will not open is an entry that is not there, '
            . 'because the answer is rebuilt from what it caches',
    },
    { dir => 'logs',
        store => 0,
        why => 'append-only records. A reader that cannot open one shows an empty page, '
            . 'and the writer says so in its own log',
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
    { dir => 'forms',
        store => 0,
        why => 'handler and form configuration, read by the form dispatcher, which reports '
            . 'a form it cannot deliver rather than accepting the submission (SM781)',
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
