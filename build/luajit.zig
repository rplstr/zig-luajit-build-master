// This code was originally copied from: https://github.com/natecraddock/ziglua and later modified to fix build issues related to backwards-incompatible Zig language changes.
// This code is shared under the MIT License by the original author, Nathan Craddock
// refer to https://github.com/natecraddock/ziglua/blob/90dab7e72173709353dcaaa6d911bed7655c030d/license

const std = @import("std");

const Build = std.Build;
const Step = std.Build.Step;

pub fn configure(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, upstream: *Build.Dependency, shared: bool) *Step.Compile {
    // TODO: extract this to the main build function because it is shared between all specialized build functions
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{ .name = "lua", .root_module = mod, .linkage = if (shared) .dynamic else .static });

    const minilua_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    // Compile minilua interpreter used at build time to generate files
    const minilua = b.addExecutable(.{
        .name = "minilua",
        .root_module = minilua_mod,
    });
    minilua.linkLibC();
    minilua.root_module.sanitize_c = .off;
    minilua.addCSourceFile(.{ .file = upstream.path("src/host/minilua.c") });

    // Generate the buildvm_arch.h file using minilua
    const dynasm_run = b.addRunArtifact(minilua);
    dynasm_run.addFileArg(getPathSeparatorFixedDynasm(b, target, upstream));

    // TODO: Many more flags to figure out
    if (target.result.cpu.arch.endian() == .little) {
        dynasm_run.addArgs(&.{ "-D", "ENDIAN_LE" });
    } else {
        dynasm_run.addArgs(&.{ "-D", "ENDIAN_BE" });
    }

    if (target.result.ptrBitWidth() == 64) dynasm_run.addArgs(&.{ "-D", "P64" });
    dynasm_run.addArgs(&.{ "-D", "JIT", "-D", "FFI" });

    if (target.result.abi.float() == .hard) {
        dynasm_run.addArgs(&.{ "-D", "FPU", "-D", "HFABI" });
    }

    if (target.result.os.tag == .windows) dynasm_run.addArgs(&.{ "-D", "WIN" });

    dynasm_run.addArg("-o");
    const buildvm_arch_h = dynasm_run.addOutputFileArg("buildvm_arch.h");

    dynasm_run.addFileArg(upstream.path(switch (target.result.cpu.arch) {
        .x86 => "src/vm_x86.dasc",
        .x86_64 => "src/vm_x64.dasc",
        .arm, .armeb => "src/vm_arm.dasc",
        .aarch64, .aarch64_be => "src/vm_arm64.dasc",
        .powerpc, .powerpcle => "src/vm_ppc.dasc",
        .mips, .mipsel => "src/vm_mips.dasc",
        .mips64, .mips64el => "src/vm_mips64.dasc",
        else => @panic("Unsupported architecture"),
    }));

    // Generate luajit.h using minilua
    const genversion_run = b.addRunArtifact(minilua);
    genversion_run.addFileArg(upstream.path("src/host/genversion.lua"));
    genversion_run.addFileArg(upstream.path("src/luajit_rolling.h"));
    genversion_run.addFileArg(b.path("build/luajit_relver.txt"));
    const luajit_h = genversion_run.addOutputFileArg("luajit.h");

    // LuaJIT doesn't cross compile very well...
    // We need to execute buildvm on the target architecture, but we can use QEMU if available
    // However, we can't use the target directly since it may not be compatible (i.e. GNU on NixOS)
    const buildvm_target = blk: {
        if (target.result.cpu.arch != @import("builtin").target.cpu.arch) {
            var query = target.query;
            query.abi = .default(target.result.cpu.arch, @import("builtin").os.tag);
            break :blk b.resolveTargetQuery(query);
        }
        break :blk target;
    };

    const buildvm_mod = b.createModule(.{
        .target = buildvm_target,
        .optimize = .ReleaseSafe,
    });
    // Compile the buildvm executable used to generate other files
    const buildvm = b.addExecutable(.{
        .name = "buildvm",
        .root_module = buildvm_mod,
    });
    buildvm.linkLibC();
    buildvm.root_module.sanitize_c = .off;

    // Needs to run after the buildvm_arch.h and luajit.h files are generated
    buildvm.step.dependOn(&dynasm_run.step);
    buildvm.step.dependOn(&genversion_run.step);

    buildvm.addCSourceFiles(.{
        .root = .{ .dependency = .{
            .dependency = upstream,
            .sub_path = "",
        } },
        .files = &.{ "src/host/buildvm_asm.c", "src/host/buildvm_fold.c", "src/host/buildvm_lib.c", "src/host/buildvm_peobj.c", "src/host/buildvm.c" },
    });

    buildvm.addIncludePath(upstream.path("src"));
    buildvm.addIncludePath(upstream.path("src/host"));
    buildvm.addIncludePath(buildvm_arch_h.dirname());
    buildvm.addIncludePath(luajit_h.dirname());

    // Use buildvm to generate files and headers used in the final vm
    const buildvm_bcdef = b.addRunArtifact(buildvm);
    buildvm_bcdef.addArgs(&.{ "-m", "bcdef", "-o" });
    const bcdef_header = buildvm_bcdef.addOutputFileArg("lj_bcdef.h");
    for (luajit_lib) |file| {
        buildvm_bcdef.addFileArg(upstream.path(file));
    }

    const buildvm_ffdef = b.addRunArtifact(buildvm);
    buildvm_ffdef.addArgs(&.{ "-m", "ffdef", "-o" });
    const ffdef_header = buildvm_ffdef.addOutputFileArg("lj_ffdef.h");
    for (luajit_lib) |file| {
        buildvm_ffdef.addFileArg(upstream.path(file));
    }

    const buildvm_libdef = b.addRunArtifact(buildvm);
    buildvm_libdef.addArgs(&.{ "-m", "libdef", "-o" });
    const libdef_header = buildvm_libdef.addOutputFileArg("lj_libdef.h");
    for (luajit_lib) |file| {
        buildvm_libdef.addFileArg(upstream.path(file));
    }

    const buildvm_recdef = b.addRunArtifact(buildvm);
    buildvm_recdef.addArgs(&.{ "-m", "recdef", "-o" });
    const recdef_header = buildvm_recdef.addOutputFileArg("lj_recdef.h");
    for (luajit_lib) |file| {
        buildvm_recdef.addFileArg(upstream.path(file));
    }

    const buildvm_folddef = b.addRunArtifact(buildvm);
    buildvm_folddef.addArgs(&.{ "-m", "folddef", "-o" });
    const folddef_header = buildvm_folddef.addOutputFileArg("lj_folddef.h");
    buildvm_folddef.addFileArg(upstream.path("src/lj_opt_fold.c"));

    const buildvm_ljvm = b.addRunArtifact(buildvm);
    buildvm_ljvm.addArg("-m");

    if (target.result.os.tag == .windows) {
        buildvm_ljvm.addArg("peobj");
    } else if (target.result.os.tag.isDarwin()) {
        buildvm_ljvm.addArg("machasm");
    } else {
        buildvm_ljvm.addArg("elfasm");
    }

    buildvm_ljvm.addArg("-o");
    if (target.result.os.tag == .windows) {
        const ljvm_ob = buildvm_ljvm.addOutputFileArg("lj_vm.o");
        lib.addObjectFile(ljvm_ob);
    } else {
        const ljvm_asm = buildvm_ljvm.addOutputFileArg("lj_vm.S");
        lib.addAssemblyFile(ljvm_asm);
    }

    // Finally build LuaJIT after generating all the files
    lib.step.dependOn(&genversion_run.step);
    lib.step.dependOn(&buildvm_bcdef.step);
    lib.step.dependOn(&buildvm_ffdef.step);
    lib.step.dependOn(&buildvm_libdef.step);
    lib.step.dependOn(&buildvm_recdef.step);
    lib.step.dependOn(&buildvm_folddef.step);
    lib.step.dependOn(&buildvm_ljvm.step);

    lib.linkLibC();

    lib.root_module.addCMacro("LUAJIT_UNWIND_EXTERNAL", "1");
    lib.linkSystemLibrary("unwind");
    lib.root_module.unwind_tables = .sync;

    // Zig's compiler_rt does not provide this architecture-specific function.
    // Thankfully, Clang provides a builtin to accomplish the same thing.
    lib.root_module.addCMacro("__clear_cache", "__builtin___clear_cache");

    lib.addIncludePath(upstream.path("src"));
    lib.addIncludePath(luajit_h.dirname());
    lib.addIncludePath(bcdef_header.dirname());
    lib.addIncludePath(ffdef_header.dirname());
    lib.addIncludePath(libdef_header.dirname());
    lib.addIncludePath(recdef_header.dirname());
    lib.addIncludePath(folddef_header.dirname());

    lib.addCSourceFiles(.{
        .root = .{ .dependency = .{
            .dependency = upstream,
            .sub_path = "",
        } },
        .files = &luajit_vm,
    });

    lib.root_module.sanitize_c = .off;

    lib.installHeader(upstream.path("src/lua.h"), "lua.h");
    lib.installHeader(upstream.path("src/lualib.h"), "lualib.h");
    lib.installHeader(upstream.path("src/lauxlib.h"), "lauxlib.h");
    lib.installHeader(upstream.path("src/luaconf.h"), "luaconf.h");
    lib.installHeader(luajit_h, "luajit.h");

    return lib;
}

fn getPathSeparatorFixedDynasm(b: *Build, target: Build.ResolvedTarget, upstream: *Build.Dependency) Build.LazyPath {
    if (target.result.os.tag != .windows) {
        // Only builds on Windows have this issue, otherwise everything works as advertised.
        return upstream.path("dynasm/dynasm.lua");
    }

    const gen_fixed_dynasm_mod = b.createModule(.{
        .target = b.graph.host,
        .root_source_file = b.path("build/generate_fixed_dynasm.zig"),
    });
    const gen_fixed_dynasm = b.addExecutable(.{
        .name = "generate_fixed_dynasm",
        .root_module = gen_fixed_dynasm_mod,
    });
    const run = b.addRunArtifact(gen_fixed_dynasm);
    run.addFileArg(upstream.path("dynasm/dynasm.lua"));
    const generated = run.addOutputFileArg("dynasm.lua");

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(generated, "dynasm/dynasm.lua");
    _ = wf.addCopyFile(upstream.path("dynasm/dasm_x64.lua"), "dynasm/dasm_x64.lua");
    _ = wf.addCopyFile(upstream.path("dynasm/dasm_x86.lua"), "dynasm/dasm_x86.lua");

    return wf.getDirectory().path(b, "dynasm/dynasm.lua");
}

const luajit_lib = [_][]const u8{
    "src/lib_base.c",
    "src/lib_math.c",
    "src/lib_bit.c",
    "src/lib_string.c",
    "src/lib_table.c",
    "src/lib_io.c",
    "src/lib_os.c",
    "src/lib_package.c",
    "src/lib_debug.c",
    "src/lib_jit.c",
    "src/lib_ffi.c",
    "src/lib_buffer.c",
};

const luajit_vm = luajit_lib ++ [_][]const u8{
    "src/lj_assert.c",
    "src/lj_gc.c",
    "src/lj_err.c",
    "src/lj_char.c",
    "src/lj_bc.c",
    "src/lj_obj.c",
    "src/lj_buf.c",
    "src/lj_str.c",
    "src/lj_tab.c",
    "src/lj_func.c",
    "src/lj_udata.c",
    "src/lj_meta.c",
    "src/lj_debug.c",
    "src/lj_prng.c",
    "src/lj_state.c",
    "src/lj_dispatch.c",
    "src/lj_vmevent.c",
    "src/lj_vmmath.c",
    "src/lj_strscan.c",
    "src/lj_strfmt.c",
    "src/lj_strfmt_num.c",
    "src/lj_serialize.c",
    "src/lj_api.c",
    "src/lj_profile.c",
    "src/lj_lex.c",
    "src/lj_parse.c",
    "src/lj_bcread.c",
    "src/lj_bcwrite.c",
    "src/lj_load.c",
    "src/lj_ir.c",
    "src/lj_opt_mem.c",
    "src/lj_opt_fold.c",
    "src/lj_opt_narrow.c",
    "src/lj_opt_dce.c",
    "src/lj_opt_loop.c",
    "src/lj_opt_split.c",
    "src/lj_opt_sink.c",
    "src/lj_mcode.c",
    "src/lj_snap.c",
    "src/lj_record.c",
    "src/lj_crecord.c",
    "src/lj_ffrecord.c",
    "src/lj_asm.c",
    "src/lj_trace.c",
    "src/lj_gdbjit.c",
    "src/lj_ctype.c",
    "src/lj_cdata.c",
    "src/lj_cconv.c",
    "src/lj_ccall.c",
    "src/lj_ccallback.c",
    "src/lj_carith.c",
    "src/lj_clib.c",
    "src/lj_cparse.c",
    "src/lj_lib.c",
    "src/lj_alloc.c",
    "src/lib_aux.c",
    "src/lib_init.c",
};
