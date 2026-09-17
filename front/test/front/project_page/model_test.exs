defmodule Front.ProjectPage.ModelTest do
  use ExUnit.Case

  import Mock

  alias Front.ProjectPage.Model
  alias Front.ProjectPage.Model.LoadParams

  describe "load_from_api" do
    setup do
      Support.FakeServices.stub_responses()
    end

    test "returns data collected from APIs" do
      params =
        struct!(LoadParams,
          project_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
          organization_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
          page_token: "dae0438b-4645-49a0-8254-19e4ea7b9f89",
          direction: "next",
          user_page?: false,
          ref_types: ["branch"]
        )

      {:ok, _data, :from_api} = Model.load_from_api(params)
    end

    test "returns degraded model when workflow list times out" do
      params =
        struct!(LoadParams,
          project_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
          organization_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
          page_token: "dae0438b-4645-49a0-8254-19e4ea7b9f89",
          direction: "next",
          user_page?: false,
          ref_types: ["branch"]
        )

      with_mock Front.Models.Workflow, [:passthrough],
        list_latest_workflows: fn _ -> {:error, :timeout} end do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert data.workflows == []
        assert data.workflow_fetch_error =~ "Loading workflows timed out"
      end
    end

    test "returns degraded model when keyset workflow fetch fails" do
      params =
        struct!(LoadParams,
          project_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
          organization_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
          page_token: "",
          direction: "next",
          list_mode: "all_pipelines",
          user_page?: false,
          ref_types: ["pr"]
        )

      rpc_error = %GRPC.RPCError{status: 2, message: "Internal Server Error"}

      with_mock Front.Models.Workflow, [:passthrough],
        list_keyset: fn _ -> {:error, rpc_error} end do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert data.workflows == []
        assert data.workflow_fetch_error =~ "couldn't load workflows"
      end
    end

    test "moves the default branch workflow to the front of the first page" do
      default = workflow_card("wf-main", "main")
      feature = workflow_card("wf-feature", "feature")
      other = workflow_card("wf-other", "other")

      params = latest_params()

      with_mocks pin_mocks(
                   project: project_stub("main"),
                   listed: [feature, default, other],
                   find_latest: fn _ -> flunk("find_latest should not be called") end
                 ) do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert Enum.map(data.workflows, & &1.id) == ["wf-main", "wf-feature", "wf-other"]
      end
    end

    test "prepends the default branch workflow when it is missing from the first page" do
      feature = workflow_card("wf-feature", "feature")
      other = workflow_card("wf-other", "other")
      default = workflow_card("wf-main", "main")

      params = latest_params()

      with_mocks pin_mocks(
                   project: project_stub("main"),
                   listed: [feature, other],
                   find_latest: fn _ -> default end
                 ) do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert Enum.map(data.workflows, & &1.id) == ["wf-main", "wf-feature", "wf-other"]
      end
    end

    test "keeps plumber order when the omitted default branch has no latest workflow" do
      feature = workflow_card("wf-feature", "feature")
      other = workflow_card("wf-other", "other")

      params = latest_params()

      with_mocks pin_mocks(
                   project: project_stub("main"),
                   listed: [feature, other],
                   find_latest: fn _ -> nil end
                 ) do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert Enum.map(data.workflows, & &1.id) == ["wf-feature", "wf-other"]
      end
    end

    test "drops the default branch workflow from later pages" do
      default = workflow_card("wf-main", "main")
      feature = workflow_card("wf-feature", "feature")

      params = latest_params(page_token: "next-page")

      with_mocks pin_mocks(
                   project: project_stub("main"),
                   listed: [default, feature],
                   find_latest: fn _ -> flunk("find_latest should not be called") end
                 ) do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert Enum.map(data.workflows, & &1.id) == ["wf-feature"]
      end
    end

    test "does not pin when the default branch is blank" do
      default = workflow_card("wf-main", "main")
      feature = workflow_card("wf-feature", "feature")

      params = latest_params()

      with_mocks pin_mocks(
                   project: project_stub(""),
                   listed: [feature, default],
                   find_latest: fn _ -> flunk("find_latest should not be called") end
                 ) do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert Enum.map(data.workflows, & &1.id) == ["wf-feature", "wf-main"]
      end
    end

    test "does not pin when ref types exclude branches" do
      default = workflow_card("wf-main", "main")
      pr = workflow_card("wf-pr", "feature", type: "pr")

      params = latest_params(ref_types: ["pr"])

      with_mocks pin_mocks(
                   project: project_stub("main"),
                   listed: [pr, default],
                   find_latest: fn _ -> flunk("find_latest should not be called") end
                 ) do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert Enum.map(data.workflows, & &1.id) == ["wf-pr", "wf-main"]
      end
    end

    test "does not reorder all-pipelines results" do
      default = workflow_card("wf-main", "main")
      feature = workflow_card("wf-feature", "feature")

      params = latest_params(list_mode: "all_pipelines")

      with_mocks [
        {Front.Models.Workflow, [:passthrough],
         [
           list_keyset: fn _ -> {[feature, default], "next", ""} end,
           find_latest: fn _ -> flunk("find_latest should not be called") end
         ]},
        {Front.Decorators.Workflow, [:passthrough],
         [
           decorate_many: fn workflows -> workflows end,
           decorate_one: fn workflow -> workflow end
         ]},
        {Front.Models.Project, [:passthrough], [find_by_id: fn _, _ -> project_stub("main") end]}
      ] do
        {:ok, data, :from_api} = Model.load_from_api(params)

        assert Enum.map(data.workflows, & &1.id) == ["wf-feature", "wf-main"]
      end
    end
  end

  describe "cache_key" do
    test "constructs cache key based on parameters" do
      params =
        struct!(LoadParams,
          project_id: "1",
          organization_id: "2",
          page_token: "4",
          direction: "next",
          user_page?: true,
          ref_types: ["branch", "tag"]
        )

      assert Model.cache_key(params) ==
               "#{Model.cache_prefix()}/#{Model.cache_version()}/project_id=1/ref_types=branchtag/list_mode=latest/"
    end
  end

  describe "invalidate" do
    test "deletes the cache key" do
      params =
        struct!(LoadParams,
          project_id: "1",
          organization_id: "2",
          page_token: "4",
          direction: "next",
          user_page?: true,
          ref_types: ["branch", "tag"]
        )

      cache_key = params |> Model.cache_key()
      Cacheman.put(:front, cache_key, "content")

      assert {:ok, 1} = params |> Model.invalidate()
    end
  end

  defp latest_params(overrides \\ []) do
    [
      project_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
      organization_id: "2e4ca2aa-ab16-4eb7-924d-0d698f7ca555",
      page_token: "",
      direction: "next",
      list_mode: "latest",
      user_page?: false,
      ref_types: ["branch"]
    ]
    |> Keyword.merge(overrides)
    |> then(&struct!(LoadParams, &1))
  end

  defp project_stub(default_branch) do
    %{repo_default_branch: default_branch}
  end

  defp workflow_card(id, branch_name, attrs \\ []) do
    %{id: id, type: Keyword.get(attrs, :type, "branch"), branch_name: branch_name}
  end

  defp pin_mocks(project: project, listed: listed, find_latest: find_latest) do
    [
      {Front.Models.Workflow, [:passthrough],
       [
         list_latest_workflows: fn _ -> {listed, "next", ""} end,
         find_latest: find_latest
       ]},
      {Front.Decorators.Workflow, [:passthrough],
       [
         decorate_many: fn workflows -> workflows end,
         decorate_one: fn workflow -> workflow end
       ]},
      {Front.Models.Project, [:passthrough], [find_by_id: fn _, _ -> project end]}
    ]
  end
end
