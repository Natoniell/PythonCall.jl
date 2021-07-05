"""
    mutable struct Context

A handle to a loaded instance of libpython, its interpreter, function pointers, etc.
"""
@kwdef mutable struct Context
    is_embedded :: Bool = false
    is_initialized :: Bool = false
    is_preinitialized :: Bool = false
    lib_ptr :: Ptr{Cvoid} = C_NULL
    exe_path :: Union{String, Missing} = missing
    lib_path :: Union{String, Missing} = missing
    dlopen_flags :: UInt32 = RTLD_LAZY | RTLD_DEEPBIND | RTLD_GLOBAL
    pyprogname :: Union{String, Missing} = missing
    pyprogname_w :: Any = missing
    pyhome :: Union{String, Missing} = missing
    pyhome_w :: Any = missing
    is_conda :: Bool = false
    conda_env :: Union{String, Missing} = missing
    version :: Union{VersionNumber, Missing} = missing
end

const CTX = Context()

function init_context()

    CTX.is_embedded = haskey(ENV, "JULIA_PYTHONCALL_LIBPTR")

    if CTX.is_embedded
        # In this case, getting a handle to libpython is easy
        if CTX.lib_ptr == C_NULL
            CTX.lib_ptr = Ptr{Cvoid}(parse(UInt, ENV["JULIA_PYTHONCALL_LIBPTR"]))
        end
        init_pointers()
        # Check Python is initialized
        Py_IsInitialized() == 0 && error("Python is not already initialized.")
        CTX.is_initialized = CTX.is_preinitialized = true
    elseif get(ENV, "JULIA_PYTHONCALL_EXE", "") == "PYCALL"
        error("not implemented: PyCall compatability mode")
#         # Import PyCall and use its choices for libpython
#         PyCall = get(Base.loaded_modules, PYCALL_PKGID, nothing)
#         if PyCall === nothing
#             PyCall = Base.require(PYCALL_PKGID)
#         end
#         CONFIG.exepath = PyCall.python
#         CONFIG.libpath = PyCall.libpython
#         CONFIG.libptr = dlopen_e(CONFIG.libpath, CONFIG.dlopenflags)
#         if CONFIG.libptr == C_NULL
#             error("Python library $(repr(CONFIG.libpath)) (from PyCall) could not be opened.")
#         end
#         CONFIG.pyprogname = PyCall.pyprogramname
#         CONFIG.pyhome = PyCall.PYTHONHOME
#         C.init_pointers()
#         # Check Python is initialized
#         C.Py_IsInitialized() == 0 && error("Python is not already initialized.")
#         CONFIG.isinitialized = CONFIG.preinitialized = true
    else
        # Find Python executable
        exe_path = something(
            CTX.exe_path===missing ? nothing : CTX.exe_path,
            get(ENV, "JULIA_PYTHONCALL_EXE", nothing),
            Sys.which("python3"),
            Sys.which("python"),
            get(ENV, "JULIA_PKGEVAL", "") == "true" ? "CONDA" : nothing,
            Some(nothing),
        )
        if exe_path === nothing
            error(
                """
              Could not find Python executable.

              Ensure 'python3' or 'python' is in your PATH or set environment variable 'JULIA_PYTHONCALL_EXE'
              to the path to the Python executable.
              """,
            )
        end
        if CTX.is_conda !== false && (exe_path == "CONDA" || startswith(exe_path, "CONDA:"))
            CTX.is_conda = true
            CTX.conda_env = exepath == "CONDA" ? Conda.ROOTENV : exe_path[7:end]
            Conda._install_conda(CTX.conda_env)
            exe_path = joinpath(
                Conda.python_dir(CTX.condaenv),
                Sys.iswindows() ? "python.exe" : "python",
            )
        end
        if isfile(exe_path)
            CTX.exe_path = exe_path
        else
            error("""
                Python executable $(repr(exe_path)) does not exist.

                Ensure either:
                - python3 or python is in your PATH
                - JULIA_PYTHONCALL_EXE is "CONDA", "CONDA:<env>" or "PYCALL"
                - JULIA_PYTHONCALL_EXE is the path to the Python executable
                """)
        end

        # For calling Python with UTF-8 IO
        function python_cmd(args)
            env = copy(ENV)
            env["PYTHONIOENCODING"] = "UTF-8"
            setenv(`$(CTX.exe_path) $args`, env)
        end

        # Find Python library
        lib_path = something(
            CTX.lib_path===missing ? nothing : CTX.lib_path,
            get(ENV, "JULIA_PYTHONCALL_LIB", nothing),
            Some(nothing)
        )
        if lib_path !== nothing
            lib_ptr = dlopen_e(lib_path, CTX.dlopen_flags)
            if lib_ptr == C_NULL
                error("Python library $(repr(lib_path)) could not be opened.")
            else
                CTX.lib_path = lib_path
                CTX.lib_ptr = lib_ptr
            end
        else
            for lib_path in readlines(python_cmd([joinpath(@__DIR__, "find_libpython.py"), "--list-all"]))
                lib_ptr = dlopen_e(lib_path, CTX.dlopen_flags)
                if lib_ptr == C_NULL
                    @warn "Python library $(repr(lib_path)) could not be opened."
                else
                    CTX.lib_path = lib_path
                    CTX.lib_ptr = lib_ptr
                    break
                end
            end
            CTX.lib_path === nothing && error("""
                Could not find Python library for Python executable $(repr(CTX.exe_path)).

                If you know where the library is, set environment variable 'JULIA_PYTHONCALL_LIB' to its path.
                """)
        end
        init_pointers()

        # Compare libpath with PyCall
        PyCall = get(Base.loaded_modules, PYCALL_PKGID, nothing)
        if PyCall === nothing
            @require PyCall="438e738f-606a-5dbb-bf0a-cddfbfd45ab0" check_libpath(PyCall)
        else
            check_libpath(PyCall)
        end

        # Initialize
        with_gil() do
            if Py_IsInitialized() != 0
                # Already initialized (maybe you're using PyCall as well)
            else
                # Find ProgramName and PythonHome
                script = if Sys.iswindows()
                    """
                    import sys
                    print(sys.executable)
                    if hasattr(sys, "base_exec_prefix"):
                        sys.stdout.write(sys.base_exec_prefix)
                    else:
                        sys.stdout.write(sys.exec_prefix)
                    """
                else
                    """
                    import sys
                    print(sys.executable)
                    if hasattr(sys, "base_exec_prefix"):
                        sys.stdout.write(sys.base_prefix)
                        sys.stdout.write(":")
                        sys.stdout.write(sys.base_exec_prefix)
                    else:
                        sys.stdout.write(sys.prefix)
                        sys.stdout.write(":")
                        sys.stdout.write(sys.exec_prefix)
                    """
                end
                CTX.pyprogname, CTX.pyhome = readlines(python_cmd(["-c", script]))

                # Set PythonHome
                CTX.pyhome_w = Base.cconvert(Cwstring, CTX.pyhome)
                Py_SetPythonHome(pointer(CTX.pyhome_w))

                # Set ProgramName
                CTX.pyprogname_w = Base.cconvert(Cwstring, CTX.pyprogname)
                Py_SetProgramName(pointer(CTX.pyprogname_w))

                # Start the interpreter and register exit hooks
                Py_InitializeEx(0)
                atexit() do
                    CTX.is_initialized = false
                    if CTX.version === missing || CTX.version < v"3.6"
                        Py_Finalize()
                    else
                        if Py_FinalizeEx() == -1
                            @warn "Py_FinalizeEx() error"
                        end
                    end
                end
            end
            CTX.is_initialized = true
            if Py_AtExit(@cfunction(() -> (CTX.is_initialized && @warn("Python exited unexpectedly"); CTX.is_initialized = false; nothing), Cvoid, ())) == -1
                @warn "Py_AtExit() error"
            end
        end
    end

#     C.PyObject_TryConvert_AddRule("builtins.object", PyObject, CTryConvertRule_wrapref, -100)
#     C.PyObject_TryConvert_AddRule("builtins.object", PyRef, CTryConvertRule_wrapref, -200)
#     C.PyObject_TryConvert_AddRule("collections.abc.Sequence", PyList, CTryConvertRule_wrapref, 100)
#     C.PyObject_TryConvert_AddRule("collections.abc.Set", PySet, CTryConvertRule_wrapref, 100)
#     C.PyObject_TryConvert_AddRule("collections.abc.Mapping", PyDict, CTryConvertRule_wrapref, 100)
#     C.PyObject_TryConvert_AddRule("_io._IOBase", PyIO, CTryConvertRule_trywrapref, 100)
#     C.PyObject_TryConvert_AddRule("io.IOBase", PyIO, CTryConvertRule_trywrapref, 100)
#     C.PyObject_TryConvert_AddRule("<buffer>", PyArray, CTryConvertRule_trywrapref, 200)
#     C.PyObject_TryConvert_AddRule("<buffer>", Array, CTryConvertRule_PyArray_tryconvert, 0)
#     C.PyObject_TryConvert_AddRule("<buffer>", PyBuffer, CTryConvertRule_wrapref, -200)
#     C.PyObject_TryConvert_AddRule("<arrayinterface>", PyArray, CTryConvertRule_trywrapref, 200)
#     C.PyObject_TryConvert_AddRule("<arrayinterface>", Array, CTryConvertRule_PyArray_tryconvert, 0)
#     C.PyObject_TryConvert_AddRule("<arraystruct>", PyArray, CTryConvertRule_trywrapref, 200)
#     C.PyObject_TryConvert_AddRule("<arraystruct>", Array, CTryConvertRule_PyArray_tryconvert, 0)
#     C.PyObject_TryConvert_AddRule("<array>", PyArray, CTryConvertRule_trywrapref, 0)
#     C.PyObject_TryConvert_AddRule("<array>", Array, CTryConvertRule_PyArray_tryconvert, 0)

    with_gil() do

#         @pyg `import sys, os`

#         pywordsize = (@pyv `sys.maxsize > 2**32`::Bool) ? 64 : 32
#         pywordsize == Sys.WORD_SIZE || error("Julia is $(Sys.WORD_SIZE)-bit but Python is $(pywordsize)-bit (at $(CONFIG.exepath ? "unknown location" : CONFIG.exepath))")

#         if !CONFIG.isembedded
#             @py ```
#             # Some modules expect sys.argv to be set
#             sys.argv = [""]
#             sys.argv.extend($ARGS)

#             # Some modules test for interactivity by checking if sys.ps1 exists
#             if $(isinteractive()) and not hasattr(sys, "ps1"):
#                 sys.ps1 = ">>> "
#             ```
#         end

        # # Is this the same Python as in Conda?
        # if CTX.is_conda &&
        #    haskey(ENV, "CONDA_PREFIX") &&
        #    isdir(ENV["CONDA_PREFIX"]) &&
        #    haskey(ENV, "CONDA_PYTHON_EXE") &&
        #    isfile(ENV["CONDA_PYTHON_EXE"]) &&
        #    realpath(ENV["CONDA_PYTHON_EXE"]) == realpath(
        #        CTX.exe_path === nothing ? @pyv(`sys.executable`::String) : CTX.exe_path,
        #    )

        #     CTX.isconda = true
        #     CTX.condaenv = ENV["CONDA_PREFIX"]
        #     CTX.exepath === nothing && (CTX.exepath = @pyv(`sys.executable`::String))
        # end

        # Get the python version
        verstr = Base.unsafe_string(Py_GetVersion())
        vermatch = match(r"^[0-9.]+", verstr)
        if vermatch === nothing
            error("Cannot parse version from version string: $(repr(verstr))")
        end
        CTX.version = VersionNumber(vermatch.match)
        v"3" ≤ CTX.version < v"4" || error(
            "Only Python 3 is supported, this is Python $(CTX.version) at $(CTX.exe_path===missing ? "unknown location" : CTX.exe_path).",
        )

#         # EXPERIMENTAL: hooks to perform actions when certain modules are loaded
#         if !CONFIG.isembedded
#             @py ```
#             import sys
#             class JuliaCompatHooks:
#                 def __init__(self):
#                     self.hooks = {}
#                 def find_module(self, name, path=None):
#                     hs = self.hooks.get(name)
#                     if hs is not None:
#                         for h in hs:
#                             h()
#                 def add_hook(self, name, h):
#                     if name not in self.hooks:
#                         self.hooks[name] = [h]
#                     else:
#                         self.hooks[name].append(h)
#                     if name in sys.modules:
#                         h()
#             JULIA_COMPAT_HOOKS = JuliaCompatHooks()
#             sys.meta_path.insert(0, JULIA_COMPAT_HOOKS)

#             # Before Qt is loaded, fix the path used to look up its plugins
#             qtfix_hook = $(() -> (CONFIG.qtfix && fix_qt_plugin_path(); nothing))
#             JULIA_COMPAT_HOOKS.add_hook("PyQt4", qtfix_hook)
#             JULIA_COMPAT_HOOKS.add_hook("PyQt5", qtfix_hook)
#             JULIA_COMPAT_HOOKS.add_hook("PySide", qtfix_hook)
#             JULIA_COMPAT_HOOKS.add_hook("PySide2", qtfix_hook)
#             ```

#             @require IJulia = "7073ff75-c697-5162-941a-fcdaad2a7d2a" begin
#                 IJulia.push_postexecute_hook() do
#                     CONFIG.pyplotautoshow && pyplotshow()
#                 end
#             end
#         end

#         # EXPERIMENTAL: IPython integration
#         if CONFIG.isembedded && CONFIG.ipythonintegration
#             if !CONFIG.isipython
#                 @py ```
#                 try:
#                     ok = "IPython" in sys.modules and sys.modules["IPython"].get_ipython() is not None
#                 except:
#                     ok = False
#                 $(CONFIG.isipython::Bool) = ok
#                 ```
#             end
#             if CONFIG.isipython
#                 # Set `Base.stdout` to `sys.stdout` and ensure it is flushed after each execution
#                 @eval Base stdout = $(@pyv `sys.stdout`::PyIO)
#                 pushdisplay(TextDisplay(Base.stdout))
#                 pushdisplay(IPythonDisplay())
#                 @py ```
#                 mkcb = lambda cb: lambda: cb()
#                 sys.modules["IPython"].get_ipython().events.register("post_execute", mkcb($(() -> flush(Base.stdout))))
#                 ```
#             end
#         end
    end

    @debug "Initialized PythonCall.jl" CTX.is_embedded CTX.is_initialized CTX.exe_path CTX.lib_path CTX.lib_ptr CTX.pyprogname CTX.pyhome CTX.version, CTX.is_conda CTX.conda_env

    return
end

function Base.show(io::IO, ::MIME"text/plain", ctx::Context)
    show(io, typeof(io))
    print(io, ":")
    for k in fieldnames(Context)
        println(io)
        print(io, "  ", k, " = ")
        show(io, getfield(ctx, k))
    end
end

const PYCALL_UUID = Base.UUID("438e738f-606a-5dbb-bf0a-cddfbfd45ab0")
const PYCALL_PKGID = Base.PkgId(PYCALL_UUID, "PyCall")

check_libpath(PyCall) = begin
    if realpath(PyCall.libpython) == realpath(CTX.lib_path)
        # @info "libpython path agrees between PythonCall and PyCall" PythonCall.CONFIG.libpath PyCall.libpython
    else
        @warn "PythonCall and PyCall are using different versions of libpython. This will probably go badly." CTX.lib_path PyCall.libpython
    end
end