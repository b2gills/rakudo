my class X::Proc::Async::TapBeforeSpawn is Exception {
    has $.handle;
    method message() {
        "To avoid data races, you must tap $!handle before running the process"
    }
}

my class X::Proc::Async::CharsOrBytes is Exception {
    has $.handle;
    method message() {
        "Can only tap one of chars or bytes supply for process $!handle"
    }
}

my class X::Proc::Async::AlreadyStarted is Exception {
    method message() {
        "Process has already been started"
    }
}

my class X::Proc::Async::MustBeStarted is Exception {
    has $.method;
    method message() {
        "Process must be started first before calling '$!method'"
    }
}

my class X::Proc::Async::OpenForWriting is Exception {
    has $.method;
    method message() {
        "Process must be opened for writing with :w to call '$!method'"
    }
}

my class Proc::Async {
    my class ProcessCancellation is repr('AsyncTask') { }
    my enum  CharsOrBytes ( :Bytes(0), :Chars(1) );

    has $.path;
    has @.args;
    has $.w;
    has Bool $!started;
    has $!stdout_supply;
    has CharsOrBytes $!stdout_type;
    has $!stderr_supply;
    has CharsOrBytes $!stderr_type;
    has $!process_handle;
    has $!exit_promise;
    has @!promises;

    proto method new(|) { * }
    multi method new($path, *@args, :$w) { self.bless(:$path,:@args,:$w) }
    multi method new(:$path!, :@args, :$w) {
        DEPRECATED( 'new($path,@args)', :what('new(:path(),:args()) (from Proc::Async)') );
        self.bless(:$path,:@args,:$w);
    }

    method !supply(\what,\supply,\type,\value) is hidden_from_backtrace {
        X::Proc::Async::TapBeforeSpawn.new(handle => what).throw
          if $!started;
        X::Proc::Async::CharsOrBytes.new(handle => what).throw
          if supply and type != value;

        type     = value;
        supply //= Supply.new;
    }

    proto method stdout(|) { * }
    multi method stdout(Proc::Async:D:) {
        self!supply('stdout', $!stdout_supply, $!stdout_type, Chars);
    }
    multi method stdout(Proc::Async:D: :$bin!) {
        self!supply('stdout',$!stdout_supply,$!stdout_type,$bin ?? Bytes !! Chars);
    }

    proto method stderr(|) { * }
    multi method stderr(Proc::Async:D:) {
        self!supply('stderr', $!stderr_supply, $!stderr_type, Chars);
    }
    multi method stderr(Proc::Async:D: :$bin!) {
        self!supply('stderr',$!stderr_supply,$!stderr_type,$bin ?? Bytes !! Chars);
    }

    method stdout_chars(Proc::Async:D:) {
        DEPRECATED('stdout');
        self.stdout;
    }

    method stdout_bytes(Proc::Async:D:) {
        DEPRECATED('stdout(:bin)');
        self.stdout(:bin);
    }

    method stderr_chars(Proc::Async:D:) {
        DEPRECATED('stderr');
        self.stderr;
    }

    method stderr_bytes(Proc::Async:D:) {
        DEPRECATED('stderr(:bin)');
        self.stderr(:bin);
    }

    method !capture(\callbacks,\std,\type,\supply) {

        my $promise = Promise.new;
        my $lock = Lock.new;
        my int $last_seq = -1;
        my int $moreing;

        nqp::bindkey(callbacks,
            std ~ ( type ?? '_chars' !! '_bytes' ),
            -> Mu \seq, Mu \data, Mu \err {
                if err {
                    $promise.keep( (supply,err) );
                }
                elsif seq < 0 {
                    $promise.keep( supply );
                }
                else {
#say "{std}: seq = {seq} with {data}   in {$*THREAD}" if std eq 'stdout';
                    supply.more(data);
                }
            }
        );
        $promise;
    }

    method start(Proc::Async:D: :$scheduler = $*SCHEDULER, :$ENV) {
        X::Proc::Async::AlreadyStarted.new.throw if $!started;
        $!started = True;

        my %ENV := $ENV ?? $ENV.hash !! %*ENV;
        my Mu $hash-with-containers := nqp::getattr(%ENV, EnumMap, '$!storage');
        my Mu $hash-without         := nqp::hash();
        my Mu $enviter := nqp::iterator($hash-with-containers);
        my $envelem;
        while $enviter {
            $envelem := nqp::shift($enviter);
            nqp::bindkey($hash-without, nqp::iterkey_s($envelem), nqp::decont(nqp::iterval($envelem)))
        }

        my Mu $args-without := nqp::list(nqp::decont($!path.Str));
        for @!args.eager {
            nqp::push($args-without, nqp::decont(.Str));
        }

        $!exit_promise = Promise.new;

        my Mu $callbacks := nqp::hash();
        nqp::bindkey($callbacks, 'done', -> Mu \status {
            $!exit_promise.keep(Proc::Status.new(:exit(status)))
        });
        nqp::bindkey($callbacks, 'error', -> Mu \err {
            $!exit_promise.break(err);
        });

        @!promises.push(
          self!capture($callbacks,'stdout',$!stdout_type,$!stdout_supply)
        ) if $!stdout_supply;
        @!promises.push(
          self!capture($callbacks,'stderr',$!stderr_type,$!stderr_supply)
        ) if $!stderr_supply;

        nqp::bindkey($callbacks, 'buf_type', buf8.new);
        nqp::bindkey($callbacks, 'write', True) if $.w;

        $!process_handle := nqp::spawnprocasync($scheduler.queue,
            $args-without, $*CWD.Str, $hash-without, $callbacks);

        Promise.allof( $!exit_promise, @!promises ).then( {
            for @!promises -> $promise {
                given $promise.result {
                    when Supply { .done }
                    when Parcel { $_[0].quit( $_[1] ) }
                }
            }
            $!exit_promise.result;
        } );
    }

    method print(Proc::Async:D: $str as Str, :$scheduler = $*SCHEDULER) {
        X::Proc::Async::OpenForWriting(:method<print>).new.throw if !$!w;
        X::Proc::Async::MustBeStarted(:method<print>).new.throw  if !$!started;

        my $p = Promise.new;
        my $v = $p.vow;
        nqp::asyncwritestr(
            $!process_handle,
            $scheduler.queue,
            -> Mu \bytes, Mu \err {
                if err {
                    $v.break(err);
                }
                else {
                    $v.keep(bytes);
                }
            },
            nqp::unbox_s($str), ProcessCancellation);
        $p
    }

    method say(Proc::Async:D: $str as Str, |c) {
        X::Proc::Async::OpenForWriting(:method<say>).new.throw if !$!w;
        X::Proc::Async::MustBeStarted(:method<say>).new.throw  if !$!started;

        self.print( $str ~ "\n", |c );
    }

    method write(Proc::Async:D: Buf $b, :$scheduler = $*SCHEDULER) {
        X::Proc::Async::OpenForWriting.new(:method<write>).throw if !$!w;
        X::Proc::Async::MustBeStarted.new(:method<write>).throw  if !$!started;

        my $p = Promise.new;
        my $v = $p.vow;
        nqp::asyncwritebytes(
            $!process_handle,
            $scheduler.queue,
            -> Mu \bytes, Mu \err {
                if err {
                    $v.break(err);
                }
                else {
                    $v.keep(bytes);
                }
            },
            nqp::decont($b), ProcessCancellation);
        $p
    }

    method close_stdin(Proc::Async:D:) {
        DEPRECATED('close-stdin');
        self.close-stdin;
    }
    method close-stdin(Proc::Async:D:) {
        X::Proc::Async::OpenForWriting.new(:method<close-stdin>).throw
          if !$!w;
        X::Proc::Async::MustBeStarted.new(:method<close-stdin>).throw
          if !$!started;

        nqp::closefh($!process_handle);
        True;
    }

    proto method kill(|) { * }
    multi method kill(Proc::Async:D: Int $signal) {
        X::Proc::Async::MustBeStarted.new(:method<kill>).throw if !$!started;

        nqp::killprocasync($!process_handle, $signal);
    }
    multi method kill(Proc::Async:D: $signal = "HUP") {
        X::Proc::Async::MustBeStarted.new(:method<kill>).throw if !$!started;

        nqp::killprocasync($!process_handle, $*KERNEL.signal($signal));
    }
}
