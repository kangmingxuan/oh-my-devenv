using System;
using System.IO;
using System.Text.RegularExpressions;

static class Phase4Stub
{
    static readonly string Root = Environment.GetEnvironmentVariable("OH_MY_DEVENV_TEST_PHASE4");
    static readonly string RuntimeBin = Path.Combine(Root, "runtime-bin");
    static readonly string Stub = Path.Combine(Root, "stub.exe");
    static readonly string ToolDir = Environment.GetEnvironmentVariable("UV_TOOL_DIR");
    static readonly string ToolBin = Environment.GetEnvironmentVariable("UV_TOOL_BIN_DIR");

    static void Log(string action)
    {
        File.AppendAllText(Path.Combine(Root, "phase4.log"), action + "\n");
    }

    static void CopyExecutable(string directory, string name)
    {
        Directory.CreateDirectory(directory);
        File.Copy(Stub, Path.Combine(directory, name + ".exe"), true);
    }

    public static int Run(string program, string[] args)
    {
        string command = String.Join(" ", args);
        if (program == "mise")
        {
            if (command == "activate pwsh")
            {
                Console.WriteLine("$env:PATH = '" + RuntimeBin.Replace("'", "''") + ";' + $env:PATH");
                return 0;
            }
            if (!String.Equals(Directory.GetCurrentDirectory(), Environment.GetEnvironmentVariable("SystemDrive") + "\\", StringComparison.OrdinalIgnoreCase))
                return 89;
            if (command == "--version")
                Console.WriteLine("mise fixture");
            else if (command == "install --yes")
            {
                Log("mise install");
                foreach (string name in File.ReadAllLines(Path.Combine(Root, "mise-tools.txt")))
                    CopyExecutable(RuntimeBin, name);
            }
            else if (command == "ls --current --missing --no-header")
            {
                foreach (string name in File.ReadAllLines(Path.Combine(Root, "mise-tools.txt")))
                    if (!File.Exists(Path.Combine(RuntimeBin, name + ".exe")))
                        Console.WriteLine(name);
            }
            else if (command == "list" || command == "ls --current --json")
                Console.WriteLine(File.ReadAllText(Path.Combine(Root, "mise-inventory.json")));
            else if (args.Length == 2 && args[0] == "which")
                Console.WriteLine(Path.Combine(RuntimeBin, args[1] + ".exe"));
            else
                return 91;
            return 0;
        }
        if (program == "go")
        {
            if (args.Length == 2 && args[0] == "install")
            {
                string spec = args[1];
                int separator = spec.LastIndexOf('@');
                string package = spec.Substring(0, separator);
                string name = Regex.Replace(package, @"/v([2-9]|[1-9][0-9]+)$", "");
                name = name.Substring(name.LastIndexOf('/') + 1);
                string bin = Environment.GetEnvironmentVariable("GOBIN");
                CopyExecutable(bin, name);
                File.WriteAllLines(Path.Combine(bin, name + ".fixture-build-info"), new[] {
                    "\tpath\t" + package,
                    "\tmod\t" + package + "\t" + spec.Substring(separator + 1)
                });
                Log("go install " + spec);
                return 0;
            }
            if (args.Length == 3 && args[0] == "version" && args[1] == "-m" && File.Exists(args[2]))
            {
                Console.Write(File.ReadAllText(Path.ChangeExtension(args[2], ".fixture-build-info")));
                return 0;
            }
            return 92;
        }
        if (program == "python" && args.Length == 2 && args[0] == "-c")
        {
            Console.WriteLine(File.ReadAllText(Path.Combine(Root, "mise-python-version")));
            return 0;
        }
        if (program == "uv")
        {
            if (command == "tool dir")
                Console.WriteLine(ToolDir);
            else if (command == "tool dir --bin")
                Console.WriteLine(ToolBin);
            else if (command == "tool list")
            {
                if (Directory.Exists(ToolDir))
                    foreach (string directory in Directory.GetDirectories(ToolDir))
                        Console.WriteLine(Path.GetFileName(directory) + " v" + File.ReadAllText(Path.Combine(directory, "fixture-version")));
            }
            else if (args.Length == 5 && args[0] == "tool" && args[1] == "install" && args[2] == "--python" &&
                     args[3] == Path.Combine(RuntimeBin, "python.exe"))
            {
                string[] requirement = args[4].Split(new[] { "==" }, StringSplitOptions.None);
                string name = Regex.Replace(requirement[0], @"[\s\[=~!<>@].*$", "");
                string directory = Path.Combine(ToolDir, name);
                CopyExecutable(Path.Combine(directory, "Scripts"), "python");
                CopyExecutable(ToolBin, name);
                File.WriteAllText(Path.Combine(directory, "fixture-version"), requirement.Length > 1 ? requirement[requirement.Length - 1] : "0");
                File.WriteAllText(Path.Combine(directory, "pyvenv.cfg"), "version_info = " + File.ReadAllText(Path.Combine(Root, "mise-python-version")));
                Log("uv install " + args[4]);
            }
            else if (args.Length == 3 && args[0] == "tool" && args[1] == "uninstall")
            {
                Directory.Delete(Path.Combine(ToolDir, args[2]), true);
                File.Delete(Path.Combine(ToolBin, args[2] + ".exe"));
                Log("uv uninstall " + args[2]);
            }
            else
                return 93;
            return 0;
        }
        return 94;
    }

    public static bool TryCompletion(string program, string command)
    {
        if (command != "completion powershell" && command != "generate-shell-completion powershell" &&
            command != "--generate-shell-completion powershell" && command != "--completion ps1")
            return false;
        Console.WriteLine("Register-ArgumentCompleter -Native -CommandName '" + program + "' -ScriptBlock { 'fixture-result' }");
        return true;
    }
}
