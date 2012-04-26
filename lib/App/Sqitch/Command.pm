package App::Sqitch::Command;

use v5.10;
use strict;
use warnings;
use utf8;
use Carp;
use Try::Tiny;
use Hash::Merge 'merge';
use Moose;

has sqitch => (is => 'ro', isa => 'App::Sqitch', required => 1);

sub command {
    my $class = ref $_[0] || shift;
    return '' if $class eq __PACKAGE__;
    my $pkg = quotemeta __PACKAGE__;
    $class =~ s/^$pkg\:://;
    return $class;
}

sub load {
    my ($class, $p) = @_;

    # We should have a command.
    $class->usage unless $p->{command};

    # Load the command class.
    my $pkg = __PACKAGE__ . "::$p->{command}";
    try {
        eval "require $pkg" or die $@;
    } catch {
        # Just die if something choked.
        die $_ unless /^Can't locate/;

        # Suggest help if it's not a valid command.
        __PACKAGE__->new({ sqitch => $p->{sqitch} })->help(
            qq{"$p->{command}" is not a valid command.}
        );
    };

    # Merge the command-line options and configuration parameters
    my $params = $pkg->configure(
        $p->{config},
        $pkg->_parse_opts($p->{args}),
    );

    # Instantiate and return the command.
    $params->{sqitch} = $p->{sqitch};
    return $pkg->new($params);
}

sub configure {
    my ($class, $config, $options) = @_;

    # Convert option keys with dashes to underscores.
    for my $k (keys %{ $options }) {
        next unless (my $nk = $k) =~ s/-/_/g;
        $options->{$nk} = delete $options->{$k};
    }

    return Hash::Merge->new->merge(
        $options,
        $config->get_section(section => $class->command),
    );
}

sub verbosity {
    shift->sqitch->verbosity;
}

sub options {
    return;
}

sub _parse_opts {
    my ($class, $args) = @_;
    return {} unless $args && @{ $args };

    my %opts;
    Getopt::Long::Configure(qw(bundling no_pass_through));
    Getopt::Long::GetOptionsFromArray($args, \%opts, $class->options)
        or $class->_pod2usage;

    return \%opts;
}

sub _bn {
    require File::Basename;
    File::Basename::basename($0);
}

sub _pod2usage {
    my ($self, %params) = @_;
    my $command = $self->command;
    require Pod::Find;
    require Pod::Usage;
    my $bn = _bn;
    $params{'-input'} ||=
                Pod::Find::pod_where({'-inc' => 1, '-script' => 1 }, "$bn-$command")
             || Pod::Find::pod_where({'-inc' => 1, '-script' => 1 }, "sqitch-$command")
             || Pod::Find::pod_where({'-inc' => 1, '-script' => 1 }, $bn)
             || Pod::Find::pod_where({'-inc' => 1, '-script' => 1 }, 'sqitch')
             || Pod::Find::pod_where({'-inc' => 1, '-script' => 1 }, ref $self || $self)
             || Pod::Find::pod_where({'-inc' => 1, '-script' => 1 }, __PACKAGE__);
    Pod::Usage::pod2usage(
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-exitval'  => 2,
        %params
    );
}

sub _prepend {
    my $prefix = shift;
    my $msg = join '', map { $_  // '' } @_;
    $msg =~ s/^/$prefix /gms;
    return $msg;
}

sub execute {
    my $self = shift;
    croak(
        'The execute() method must be called from a subclass of ',
        __PACKAGE__
    ) if ref $self eq __PACKAGE__;

    croak(
        'The execute() method has not been overridden in ',
        ref $self
    );
}

# Poached from Module::Build.
sub do_system {
    my ($self, @cmd) = @_;
    $self->trace(join ' ' => @cmd);
    my $status = system @cmd;
    $self->warn(
        "'Argument list' was 'too long', env lengths are ",
        join '' => map { "$_=>" . length($ENV{$_} . '; ') } sort keys %ENV
    ) if $status and $! =~ /Argument list too long/i;
    return !$status;
}

sub trace {
    my $self = shift;
    say _prepend 'trace:', @_ if $self->verbosity > 2
}

sub debug {
    my $self = shift;
    say _prepend 'debug:', @_ if $self->verbosity > 1
}

sub info {
    my $self = shift;
    say @_ if $self->verbosity;
}

sub comment {
    my $self = shift;
    say _prepend '#', @_ if $self->verbosity;
}

sub emit {
    shift;
    say @_;
}

sub warn {
    my $self = shift;
    say STDERR _prepend 'warning:', @_;
}

sub unfound {
    exit 1;
}

sub fail {
    my $self = shift;
    say STDERR _prepend 'fatal:', @_;
    exit 2;
}

sub help {
    my $self = shift;
    my $bn = _bn;
    say STDERR _prepend("$bn:", @_), " See $bn --help";
    exit 1;
}

sub usage {
    my $self = shift;
    require Pod::Find;
    my $upod = _bn . '-' . $self->command .  '-usage';
    $self->_pod2usage(
        '-input' => Pod::Find::pod_where({'-inc' => 1 }, $upod) || undef,
        '-message' => join '', @_
    );
}

sub bail {
    my ($self, $code) = (shift, shift);
    if (@_) {
        if ($code) {
            say STDERR @_;
        } else {
            say STDOUT @_;
        }
    }
    exit $code;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Command - Sqitch Command support

=head1 Synopsis

  my $cmd = App::Sqitch::Command->load( deploy => \%params );
  $cmd->run;

=head1 Description

App::Sqitch::Command is the base class for all Sqitch commands.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @spec = App::Sqitch::Command->options;

Returns a list of L<Getopt::Long> options specifications. When C<load> loads
the class, any options passed to the command will be parsed using these
values. The keys in the resulting hash will be the first part of each option.
This hash will be passed to C<configure> along with a L<App::Sqitch::Config>
object for munging into parameters to be passed to the constructor.

Here's an example excerpted from the C<config> command:

  sub options {
      return qw(
          get
          unset
          list
          global
          system
          config-file=s
      );
  }

This will result in hash keys with the same names as each option except for
C<config-file=s>, which will be named C<config_file>.

=head3 C<configure>

  my $params = App::Sqitch::Command->configure($config, $options);

Takes two arguments, an L<App::Sqitch::Config> object and the hash of
command-line options as specified by C<options>. The returned hash should be
the result of munging these two objects into a hash reference of parameters to
be passed to the command subclass constructor.

By default, this method converts dashes to underscores in command-line options
keys, and then merges the configuration values with the options, with the
command-line options taking priority. You may wish to override this method to
do something different.

=head2 Constructors

=head3 C<load>

  my $cmd = App::Sqitch::Command->load( \%params );

A factory method for instantiating Sqitch commands. It loads the subclass for
the specified command, uses the options returned by C<options> to parse
command-line options, calls C<configure> to merge configuration with the
options, and finally calls C<new> with the resulting hash. Supported parameters
are:

=over

=item C<sqitch>

The App::Sqitch object driving the whole thing.

=item C<config>

An L<App::Sqitch::Config> representing the current application configuration
state.

=item C<command>

The name of the command to be executed.

=item C<args>

An array reference of command-line arguments passed to the command.

=back

=head3 C<new>

  my $cmd = App::Sqitch::Command->new(%params);

Instantiates and returns a App::Sqitch::Command object. This method is not
designed to be overridden by subclasses; they should implement
L<C<BUILDARGS>|Moose::Manual::Construction/BUILDARGS> or
L<C<BUILD>|Moose::Manual::Construction/BUILD>, instead.

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $cmd->sqitch;

Returns the L<App::Sqitch> object that instantiated the command. Commands may
access its properties in order to manage global state.

=head2 Overridable Instance Methods

These methods should be overridden by all subclasses.

=head3 C<execute>

  $cmd->execute;

Executes the command. This is the method that does the work of the command.
Must be overridden in all subclasses. Dies if the method is not overridden for
the object on which it is called, or if it is called against a base
App::Sqitch::Command object.

=head3 C<command>

  my $command = $cmd->command;

The name of the command. Defaults to the last part of the package name, so as
a rule you should not need to override it, since it is that string that Sqitch
uses to find the command class.

=head2 Utility Instance Methods

These methods are mainly provided as utilities for the command subclasses to
use.

=head3 C<do_system>

  if !($cmd->do_system('echo hello')) {
      $cmd->fail('Ooops');
  }

Executes a system command and waits for it to finish. Returns true if the
command returned without error, and false if it did not.

=head3 C<verbosity>

  my $verbosity = $cmd->verbosity;

Returns the verbosity level.

=head3 C<trace>

  $cmd->trace('About to fuzzle the wuzzle.');

Send trace information to C<STDOUT> if the verbosity level is 3 or higher.
Trace messages will have C<TRACE: > prefixed to every line. If it's lower than
3, nothing will be output.

=head3 C<debug>

  $cmd->debug('Found snuggle in the crib.');

Send debug information to C<STDOUT> if the verbosity level is 2 or higher.
Debug messages will have C<DEBUG: > prefixed to every line. If it's lower than
2, nothing will be output.

=head3 C<info>

  $cmd->info('Nothing to deploy (up-to-date)');

Send informational message to C<STDOUT> if the verbosity level is 1 or higher,
which, by default, it is. Should be used for normal messages the user would
normally want to see. If verbosity is lower than 1, nothing will be output.

=head3 C<comment>

  $cmd->comment('On database flipr_test');

Send comments to C<STDOUT> if the verbosity level is 1 or higher, which, by
default, it is. Comments have C<# > prefixed to every line. If verbosity is
lower than 1, nothing will be output.

=head3 C<emit>

  $cmd->emit('core.editor=emacs');

Send a message to C<STDOUT>, without regard to the verbosity. Should be used
only if the user explicitly asks for output, such as for
C<sqitch config --get core.editor>.

=head3 C<warn>

  $cmd->warn('Could not find nerble; using nobble instead.');

Send a warning messages to C<STDERR>. Use if something unexpected happened but
you can recover from it.

=head3 C<unfound>

  $cmd->unfound;

Exit the program with status code 1. Best for use for non-fatal errors,
such as when something requested was not found.

=head3 C<fail>

  $cmd->fail('File or directory "foo" not found.');

Send a failure message to C<STDERR> and exit with status code 2. Use if
something unexpected happened and you cannot recover from it.

=head3 C<usage>

  $cmd->usage('Missing "value" argument');

Sends the specified message to C<STDERR>, followed by the usage sections of
the command's documentation. Those sections may be named "Name", "Synopsis",
or "Options". Any or all of those will be shown.

=head3 C<help>

  $cmd->help('"foo" is not a valid command.');

Sends messages to C<STDERR> and exists with an additional message to "See
sqitch --help". Use if the user has misused the app.

=head3 C<bail>

  $cmd->bail(3, 'The config file is invalid');

Exits with the specified error code, sending any specified messages to
C<STDOUT> if the exit code is 0, and to C<STDERR> if it is not 0.

=head1 See Also

=over

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut

