defmodule Glayu.Tasks.Build do

  @behaviour Glayu.Tasks.Task

  @max_posts_per_node 100
  @tasks [:scan, :pages, :categories, :home, :assets]

  alias Glayu.Build.SiteAnalyzer.ContainMdFiles
  alias Glayu.Build.TaskSpawner
  alias Glayu.Build.TemplatesStore
  alias Glayu.Build.Jobs.RenderPages
  alias Glayu.Build.Jobs.BuildSiteTree
  alias Glayu.Build.Jobs.RenderCategoryPages
  alias Glayu.Build.Jobs.BuildSiteTreeAndRenderPages
  alias Glayu.Utils.PathRegex
  alias Glayu.Build.SiteTree

  # Handles $ glayu build
  def run([regex: nil]) do
    before = System.monotonic_time()
    check_and_init()
    result = build_pipeline([:scan_and_pages, :categories, :home, :assets], [results: %{}])
    later = System.monotonic_time()
    diff = later - before
    seconds = System.convert_time_unit(diff, :native, :seconds)
    case result do
      {:ok, _} ->
        {:ok, seconds}
      _ ->
        result
    end
  end

  # Handles $ glayu build regex
  def run([regex: regex]) do
    before = System.monotonic_time()
    check_and_init()
    result = build_pipeline([:scan_and_pages], [regex: regex, results: %{}])
    later = System.monotonic_time()
    diff = later - before
    seconds = System.convert_time_unit(diff, :native, :seconds)
    case result do
      {:ok, _} ->
        {:ok, seconds}
      _ ->
        result
    end
  end

  # Handles $ glayu build --chp regex
  def run(params) do
    before = System.monotonic_time()
    check_and_init()
    result = build_pipeline([:scan] ++ params_to_tasks(params), params ++ [results: %{}])
    later = System.monotonic_time()
    diff = later - before
    seconds = System.convert_time_unit(diff, :native, :seconds)
    case result do
      {:ok, _} ->
        {:ok, seconds}
      _ ->
        result
    end
  end

  defp check_and_init() do
    Glayu.Config.load_config()
    Glayu.SiteChecker.check_site!()
    Glayu.SiteChecker.check_theme!()

    Application.start(:glayu_build)
    TemplatesStore.add_templates(Glayu.Template.compile())
  end

  defp params_to_tasks(params) do
    Enum.filter(Keyword.keys(params), &(Enum.member?(@tasks, &1)))
  end

  def build_pipeline([],  args) do
    {:ok, args[:results]}
  end

  def build_pipeline([task | tasks],  args) do
    {status, results} = run_task(task, args)
    if status == :ok do
      build_pipeline(tasks, args ++ results)
    else
      {:error, results}
    end
  end

  def run_task(:scan, args) do
    regex = args[:regex]
    root = PathRegex.base_dir(regex)

    nodes = ProgressBar.render_spinner([text: "Scanning site…", done: [IO.ANSI.light_cyan, "✓", IO.ANSI.reset, " Site scan completed."], frames: :braille, spinner_color: IO.ANSI.light_cyan], fn ->
      nodes = ContainMdFiles.nodes(root, compile_regex(regex))

      sort_fn = fn doc_context1, doc_context2 ->
        comp = DateTime.compare(doc_context1[:date], doc_context2[:date])
        comp == :gt || comp == :eq
      end

      TaskSpawner.spawn(nodes, BuildSiteTree, [sort_fn: sort_fn, num_posts: @max_posts_per_node])
      nodes
    end)

    {status, resume} = Glayu.Build.JobResume.resume(BuildSiteTree.__info__(:module))

    if status == :ok do
      IO.puts IO.ANSI.format([IO.ANSI.light_cyan, "└── #{length(SiteTree.keys())}", IO.ANSI.reset , " categories, ", IO.ANSI.light_cyan, "#{resume.files}", IO.ANSI.reset , " posts and ", IO.ANSI.light_cyan, "#{length(SiteTree.pages())}", IO.ANSI.reset ," pages added to the site tree."])
      {:ok, [nodes: nodes]}
    else
      {:error, IO.ANSI.format([["Unable to build Site Tree: "] | resume.errors])}
    end

  end

  def run_task(:scan_and_pages, args) do

    regex = args[:regex]
    root = PathRegex.base_dir(regex)

    ProgressBar.render_spinner([text: "Generating site pages…", done: [IO.ANSI.light_cyan, "✓", IO.ANSI.reset, " Site pages generated."], frames: :braille, spinner_color: IO.ANSI.light_cyan], fn ->
      nodes = ContainMdFiles.nodes(root, compile_regex(regex))

      sort_fn = fn doc_context1, doc_context2 ->
        comp = DateTime.compare(doc_context1[:date], doc_context2[:date])
        comp == :gt || comp == :eq
      end

      TaskSpawner.spawn(nodes, BuildSiteTreeAndRenderPages, [sort_fn: sort_fn, num_posts: @max_posts_per_node])

    end)

    {status, resume} = Glayu.Build.JobResume.resume(BuildSiteTreeAndRenderPages.__info__(:module))

    if status == :ok do
      IO.puts IO.ANSI.format([IO.ANSI.light_cyan, "└── #{resume.files}", IO.ANSI.reset , " pages generated."])
      {:ok, []}
    else
      {:error, IO.ANSI.format([["Unable to generate site pages: "] | resume.errors])}
    end

  end

  def run_task(:pages, args) do

    ProgressBar.render_spinner([text: "Generating site pages…", done: [IO.ANSI.light_cyan, "✓", IO.ANSI.reset, " Site pages generated."], frames: :braille, spinner_color: IO.ANSI.light_cyan], fn ->
      TaskSpawner.spawn(args[:nodes], RenderPages, [])
    end)

    {status, resume} = Glayu.Build.JobResume.resume(RenderPages.__info__(:module))

    if status == :ok do
      IO.puts IO.ANSI.format([IO.ANSI.light_cyan, "└── #{resume.files}", IO.ANSI.reset , " pages generated."])
      {:ok, []}
    else
      {:error, IO.ANSI.format([["Unable to generate site pages: "] | resume.errors])}
    end

  end

  def run_task(:categories, args) do

    ProgressBar.render_spinner([text: "Generating category pages…", done: [IO.ANSI.light_cyan, "✓", IO.ANSI.reset, " Category pages generated."], frames: :braille, spinner_color: IO.ANSI.light_cyan], fn ->

      if(args[:regex]) do
        regex = compile_regex(args[:regex])
        nodes = Enum.filter(SiteTree.keys(), fn(keys) ->
          Regex.match?(regex, Glayu.Path.category_relative_source_dir(keys))
        end)
        TaskSpawner.spawn(nodes, RenderCategoryPages, [])
      else
        TaskSpawner.spawn(SiteTree.keys(), RenderCategoryPages, [])
      end

    end)

    {status, resume} = Glayu.Build.JobResume.resume(RenderCategoryPages.__info__(:module))

    if status == :ok do
      IO.puts IO.ANSI.format([IO.ANSI.light_cyan, "└── #{resume.nodes}", IO.ANSI.reset , " category pages generated."])
      {:ok, []}
    else
      {:error, IO.ANSI.format([["Unable to generate category pages: "] | resume.errors])}
    end

  end

  def run_task(:home, _) do
    ProgressBar.render_spinner([text: "Generating home page…", done: [IO.ANSI.light_cyan, "✓", IO.ANSI.reset, " Home page generated."], frames: :braille, spinner_color: IO.ANSI.light_cyan], fn ->
      Glayu.HomePage.write(Glayu.HomePage.render())
    end)
    {:ok, []}
  end

  def run_task(:assets, _) do
    {:ok, files} = ProgressBar.render_spinner([text: "Coping site assets…", done: [IO.ANSI.light_cyan, "✓", IO.ANSI.reset, " Site assets copied from theme folder to public folder."], frames: :braille, spinner_color: IO.ANSI.light_cyan], fn ->
      File.cp_r(Glayu.Path.assets_source(), Glayu.Path.public_assets())
    end)
    IO.puts IO.ANSI.format([:light_cyan, "└── #{length(files)}", :reset , " files copied."])
    {:ok, []}
  end

  defp compile_regex(nil) do
    nil
  end

  defp compile_regex(regex) do
    Regex.compile!(regex)
  end

end