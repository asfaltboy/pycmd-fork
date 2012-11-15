#
# Common utility functions
#
import os, string, fsm, _winreg, pefile, mmap, sys, time
import re
from clib.win32api import ExpandEnvironmentStrings
from libc.stdlib cimport malloc, free
from libc.string cimport memset, strlen
from cpython.string cimport PyString_FromStringAndSize

# Check if we're running in PyPy.
PYPY = hasattr(sys, 'pypy_version_info')

# Stop points when navigating one word at a time
word_sep = [' ', '\t', '\\', '-', '_', '.', '/', '$', '&', '=', '+', '@', ':', ';']

# Command splitting characters
sep_chars = [' ', '|', '&', '>', '<']

# Command sequencing tokens
seq_tokens = ['|', '||', '&', '&&']

# Redirection tokens
digit_chars = list(string.digits)
redir_file_simple = ['>', '>>', '<']
redir_file_ext = [c + d for d in digit_chars for c in ['<&', '>&']]
redir_file_all = redir_file_simple + redir_file_ext
redir_file_tokens = redir_file_all + [d + c for d in digit_chars for c in redir_file_all]
# print redir_file_tokens

# All command splitting tokens
sep_tokens = seq_tokens + redir_file_tokens
class memoize(object):
    """ Memoize With Timeout """
    _caches = {}
    _timeouts = {}
    def __init__(self, timeout=0):
        self.timeout = timeout
    def collect(self):
        """Clear cache of results which have timed out"""
        for func in self._caches:
            cache = {}
            for key in self._caches[func]:
                if (time.time() - self._caches[func][key][1]) < self._timeouts[func]:
                    cache[key] = self._caches[func][key]
            self._caches[func] = cache
    def __call__(self, f):
        self.cache = self._caches[f] = {}
        self._timeouts[f] = self.timeout
        def func(*args, **kwargs):
            kw = kwargs.items()
            kw.sort()
            key = (args, tuple(kw))
            try:
                v = self.cache[key]
                if self.timeout == 0: return v[0]
                if (time.time() - v[1]) > self.timeout:
                    raise KeyError
            except KeyError:
                v = self.cache[key] = f(*args, **kwargs), time.time()
            return v[0]
        func.func_name = f.func_name
        return func

def parse_line(line):
    """Tokenize a command line based on whitespace while observing quotes"""

    def accumulate(fsm):
        """Action: add current symbol to last token in list."""
        fsm.memory[-1] = fsm.memory[-1] + fsm.input_symbol

    def start_empty_token(fsm):
        """Action: start a new token."""
        if fsm.memory[-1] != '':
            fsm.memory.append('')

    def start_token(fsm):
        """Action: start a new token and accumulate."""
        start_empty_token(fsm)
        accumulate(fsm)

    def accumulate_last(fsm):
        """Action: accumulate and start new token."""
        accumulate(fsm)
        start_empty_token(fsm)

    def error(fsm):
        """Action: handle uncovered transition (should never happen)."""
        print 'Unhandled transition:', (fsm.input_symbol, fsm.current_state)
        accumulate(fsm)

    f = fsm.FSM('init', [''])

    f.set_default_transition(error, 'init')

    # default
    f.add_transition_list(string.whitespace, 'init', start_empty_token, 'whitespace')
    f.add_transition('"', 'init', accumulate, 'in_string')
    f.add_transition('|', 'init', start_token, 'pipe')
    f.add_transition('&', 'init', start_token, 'amp')
    f.add_transition('>', 'init', start_token, 'gt')
    f.add_transition('<', 'init', accumulate, 'awaiting_&')
    f.add_transition('^', 'init', accumulate, 'escape')
    f.add_transition_list(string.digits, 'init', accumulate, 'redir')
    f.add_transition_any('init', accumulate, 'init')

    # whitespace
    f.add_transition_list(string.whitespace, 'whitespace', None, 'whitespace')
    f.add_empty_transition('whitespace', 'init')

    # strings
    f.add_transition('"', 'in_string', accumulate, 'init')
    f.add_transition_any('in_string', accumulate, 'in_string')

    # seen '|'
    f.add_transition('|', 'pipe', accumulate_last, 'init')
    f.add_empty_transition('pipe', 'init', start_empty_token)

    # seen '&'
    f.add_transition('&', 'amp', accumulate_last, 'init')
    f.add_empty_transition('amp', 'init', start_empty_token)

    # seen '>' or '1>' etc.
    f.add_transition('>', 'gt', accumulate, 'awaiting_&')
    f.add_transition('&', 'gt', accumulate, 'awaiting_nr')
    f.add_empty_transition('gt', 'init', start_empty_token)

    # seen digit
    f.add_transition('<', 'redir', accumulate, 'awaiting_&')
    f.add_transition('>', 'redir', accumulate, 'gt')
    f.add_empty_transition('redir', 'init')

    # seen '<' or '>>', '0<', '2>>' etc.
    f.add_transition('&', 'awaiting_&', accumulate, 'awaiting_nr')
    f.add_empty_transition('awaiting_&', 'init', start_empty_token)

    # seen '<&' or '>&', '>>&', '0<&', '1>&', '2>>&' etc.
    f.add_transition_list(string.digits, 'awaiting_nr', accumulate_last, 'init')
    f.add_empty_transition('awaiting_nr', 'init', start_empty_token)

    # seen '^'
    f.add_transition_any('escape', accumulate, 'init')

    f.process_list(line)
    if len(f.memory) > 0 and f.memory[-1] == '':
        del f.memory[-1]

    return f.memory

def old_unescape(string):
    """Unescape string from ^ escaping. ^ inside double quotes is ignored"""
    if string is None:
        return None
    result = u''
    in_quotes = False
    escape_next = False
    for c in string:
        if in_quotes:
            result += c
            if c == '"':
                in_quotes = False
        elif escape_next:
            result += c
            escape_next = False
        else:
            if c == '^':
                escape_next = True
            else:
                result += c
                if c == '"':
                    in_quotes = True

    return result

# Just curious what kind of speedup we can get here.
cdef object _unescape(char* s, size_t sz):
    cdef bint in_quotes = False
    cdef bint escape_next = False
    cdef int i, n = 0
    cdef char c
    cdef object result
    cdef size_t bufsize = sizeof(char) * (sz + 1)
    cdef char* cresult = <char*>malloc(bufsize)

    memset(cresult, 0, sz)
    for i from 0 <= i < sz:
        c = s[i]
        if in_quotes:
            cresult[n] = c
            n += 1
            if c == '"':
                in_quotes = False
        elif escape_next:
            cresult[n] = c
            n += 1
            escape_next = False
        else:
            if c == '^':
                escape_next = True
            else:
                cresult[n] = c
                n += 1
                if c == '"':
                    in_quotes = True
    result = PyString_FromStringAndSize(cresult, n)
    free(<void*>cresult)
    return result

def unescape(string):
    """ Unescape string from ^ escaping. ^ inside double quotes is ignored """
    return None if string is None else _unescape(string, len(string))

def expand_tilde(string):
    """
    Return an expanded version of the string by replacing a leading tilde
    with %HOME% (if defined) or %USERPROFILE%.
    """
    if 'HOME' in os.environ.keys():
        home_var = 'HOME'
    else:
        home_var = 'USERPROFILE'
    if string.startswith('~') or string.startswith('"~'):
        string = string.replace('~', '%' + home_var + '%', 1)
    return string

def old_expand_env_vars(string):
    """
    Return an expanded version of the string by inlining the values of the
    environment variables. Also replaces ~ with %HOME% or %USERPROFILE%.
    The provided string is expected to be a single token of a command.
    """
    # Expand tilde
    string = expand_tilde(string)

    # Expand all %variable%s
    begin = string.find('%')
    while begin >= 0:
        end = string.find('%', begin + 1)
        if end >= 0:
            # Found a %variable%
            var = string[begin:end].strip('%')
            if var.upper() in os.environ.keys():
                string = string.replace('%' + var + '%', os.environ[var], 1)
        begin = string.find('%', begin + 1)
    return string

def expand_env_vars(sinput):
    """
    Return an expanded version of the string by inlining the values of the
    environment variables. Also replaces ~ with %HOME% or %USERPROFILE%.
    The provided string is expected to be a single token of a command.
    """
    sinput = expand_tilde(sinput)
    sinput = ExpandEnvironmentStrings(sinput)
    return sinput

#@memoize()
def split_nocase(string, separator):
    """Split a string based on the separator while ignoring case"""
    chunks = []
    seps = []
    pos = string.lower().find(separator.lower())
    while pos >= 0:
        chunks.append(string[ : pos])
        seps.append(string[pos : pos + len(separator)])
        string = string[pos + len(separator) : ]
        pos = string.lower().find(separator.lower())

    chunks.append(string)
    return chunks, seps

def fuzzy_match(substr, str, prefix_only = False):
    """
    Check if a substring is part of a string, while ignoring case and
    allowing for "fuzzy" matching, i.e. require that only the "words" in
    substr be individually matched in str (instead of an full match of
    substr). The prefix_only option only matches "words" in the substr at
    word boundaries in str.
    """
    #print '\n\nMatch "' + substr + '" in "' + str + '"\n\n'
    words = substr.split(' ')
    pattern = [('\\b' if prefix_only else '') + '(' + word + ').*' for word in words]
    # print '\n\n', pattern, '\n\n'
    pattern = ''.join(pattern)
    matches = re.search(pattern, str, re.IGNORECASE)
    return [matches.span(i) for i in range(1, len(words) + 1)] if matches else []

def old_abbrev_string(string):
    """Abbreviate a string by keeping uppercase and non-alphabetical characters"""
    string_abbrev = ''
    add_next_char = True

    for char in string:
        add_this_char = add_next_char
        if char == ' ':
            add_this_char = False
            add_next_char = True
        elif not char.isalpha():
            add_this_char = True
            add_next_char = True
        elif char.isupper() and not string.isupper():
            add_this_char = True
            add_next_char = False
        else:
            add_next_char = False
        if add_this_char:
            string_abbrev += char

    return string_abbrev

cdef char* _abbrev_string(char* s, size_t sz, bint isup):
    cdef bint add_next_char = True, add_this_char = True
    cdef char c
    cdef size_t i = 0, n = 0
    for i from 0 <= i < sz:
        c = s[i]
        add_this_char = add_next_char
        if c == ' ':
            add_this_char = False
            add_next_char = True
        elif not isup and (65 <= <int>c <= 90):
            add_this_char = True
            add_next_char = False
        elif <int>c < 97 or <int>c > 122:
            add_this_char = True
            add_next_char = True
        else:
            add_next_char = False
            continue
        if add_this_char:
            s[n] = c
            n += 1
    for i from n <= i < sz:
        s[i] = <char>0
    return s

def abbrev_string(string):
    """Abbreviate a string by keeping uppercase and non-alphabetical characters"""
    return None if string is None else _abbrev_string(string, len(string), string.isupper())

_exec_exts = None
def exec_exts():
    global _exec_exts
    if _exec_exts is None:
        _exec_exts = filter(lambda v: len(v) > 0, [ v.strip() for v in os.environ['PATHEXT'].lower().split(';') ])
        if '.dll' in _exec_exts: _exec_exts.remove('.dll')
    return _exec_exts

#@memoize()
def _is_exec_extension(fext):
    return fext in exec_exts()

def has_exec_extension(filename):
    """ Check whether the specified file is executable, i.e. its extension is in PATHEXT """
    fileext = filename.lower().splitext()[0]
    return _is_exec_extension(fileext)


#@memoize()
def strip_extension(file_name):
    """ Remove extension, if present """
    dot = file_name.rfind('.')
    if dot > file_name.rfind('\\'):
        return file_name[ : dot]
    else:
        return file_name

#@memoize()
def contains_special_char(s):
    """Check whether the string contains a character that requires quoting"""
    return len(s) > 0 and ' ' in s or '&' in s


#@memoize()
def old_starts_with_special_char(s):
    """Check whether the string STARTS with a character that requires quoting"""
    return len(s) > 0 and s[0] in [' ', '&']

cpdef bint starts_with_special_char(char* s):
    return s != NULL and strlen(s) > 0 and (s[0] == ' ' or s[0] == '&')

#@memoize()
def associated_application(ext):
    """
    Scan the registry to find the application associated to a given file
    extension.
    """
    try:
        file_class = _winreg.QueryValue(_winreg.HKEY_CLASSES_ROOT, ext) or ext
        action = _winreg.QueryValue(_winreg.HKEY_CLASSES_ROOT, file_class + '\\shell') or 'open'
        assoc_key = _winreg.OpenKey(_winreg.HKEY_CLASSES_ROOT,
                                    file_class + '\\shell\\' + action + '\\command')
        open_command = _winreg.QueryValueEx(assoc_key, None)[0]

        # We assume a value `similar to '<command> %1 %2'
        return expand_env_vars(parse_line(open_command)[0])
    except WindowsError:
        return None


#@memoize(timeout=2)
def full_executable_path(app_unicode):
    """
    Compute the full path of the executable that will be spawned
    for the given command
    """
    app = app_unicode.encode(sys.getfilesystemencoding())

    # Split the app into a dir, a name and an extension; we
    # will configure our search for the actual executable based
    # on these
    dir, file = os.path.split(app.strip('"'))
    name, ext = os.path.splitext(file)

    # Determine possible executable extension
    if ext != '':
        extensions_to_search = [ext]
    else:
        extensions_to_search = exec_exts()

    # Determine the possible locations
    if dir:
        paths_to_search = [dir]
    else:
        paths_to_search = [os.getcwd()] + os.environ['PATH'].split(os.pathsep)

    # Search for an app
    # print 'D:', paths_to_search, 'N:', name, 'E:', extensions_to_search
    for p in paths_to_search:
        for e in extensions_to_search:
            full_path = os.path.join(p, name) + e
            if os.path.exists(full_path):
                return full_path

    # We could not find the executable; this might be an internal command,
    # or a file that doesn't have a registered application
    return None


#@memoize(timeout=5)
def is_gui_application(executable):
    """
    Try to guess if an executable is a GUI or console app.
    Note that the full executable name of an .exe file is
    required (use e.g. full_executable_path() to get it)
    """
    result = False
    try:
        fd = os.open(executable, os.O_RDONLY)
        m = mmap.mmap(fd, 0, access = mmap.ACCESS_READ)

        try:
            pe = pefile.PE(data = m, fast_load=True)
            if pefile.SUBSYSTEM_TYPE[pe.OPTIONAL_HEADER.Subsystem] == 'IMAGE_SUBSYSTEM_WINDOWS_GUI':
                # We only return true if all went well
                result = True
        except pefile.PEFormatError:
            # There's not much we can do if pefile fails
            pass

        m.close()
        os.close(fd)
    except Exception:
        # Not much we can do for exceptions
        pass

    # Return False when not sure
    return result
