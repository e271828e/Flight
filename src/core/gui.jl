module GUI

using UnPack

using Printf
using CImGui
using CImGui.CSyntax
using CImGui.CSyntax.CStatic
using CImGui.GLFWBackend
using CImGui.OpenGLBackend
using CImGui.GLFWBackend.GLFW
using CImGui.OpenGLBackend.ModernGL

export Renderer, CImGuiStyle

################################################################################
############################# Renderer####################################

@enum CImGuiStyle begin
    classic = 0
    dark = 1
    light = 2
end

mutable struct Renderer
    refresh::Integer
    label::String
    style::CImGuiStyle
    wsize::Tuple{Int, Int}
    _initialized::Bool
    _window::GLFW.Window
    _context::Ptr{CImGui.LibCImGui.ImGuiContext}
    function Renderer(; refresh::Integer, label::String = "Renderer",
                        wsize = (1280, 720), style::CImGuiStyle = dark)
        renderer = new()
        @pack! renderer = refresh, label, style, wsize
        renderer._initialized = false
        return renderer
    end
end

function init!(renderer::Renderer)

    @unpack refresh, label, style, wsize = renderer

    @static if Sys.isapple()
        # OpenGL 3.2 + GLSL 150
        glsl_version = 150
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3)
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 2)
        GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE) # 3.2+ only
        GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, GL_TRUE) # required on Mac
    else
        # OpenGL 3.0 + GLSL 130
        glsl_version = 130
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3)
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 0)
        # GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE) # 3.2+ only
        # GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, GL_TRUE) # 3.0+ only
    end

    # setup GLFW error callback
    error_callback(err::GLFW.GLFWError) = @error "GLFW ERROR: code $(err.code) msg: $(err.description)"
    GLFW.SetErrorCallback(error_callback)

    # create window
    _window = GLFW.CreateWindow(wsize[1], wsize[2], label)
    @assert _window != C_NULL
    GLFW.MakeContextCurrent(_window)
    GLFW.SwapInterval(refresh)

    # setup Dear ImGui context
    _context = CImGui.CreateContext()

    # setup Dear ImGui style
    style === classic && CImGui.StyleColorsClassic()
    style === dark && CImGui.StyleColorsDark()
    style === light && CImGui.StyleColorsLight()

    # setup Platform/Renderer bindings
    ImGui_ImplGlfw_InitForOpenGL(_window, true)
    ImGui_ImplOpenGL3_Init(glsl_version)

    renderer._initialized = true
    renderer._window = _window
    renderer._context = _context

    return nothing

end

function should_close(r::Renderer)
    r._initialized ? GLFW.WindowShouldClose(r._window) : false
end

function shutdown!(renderer::Renderer)

    @unpack _window, _context, _initialized = renderer
    @assert _initialized "Cannot shutdown an uninitialized renderer"

    ImGui_ImplOpenGL3_Shutdown()
    ImGui_ImplGlfw_Shutdown()
    CImGui.DestroyContext(_context)
    GLFW.DestroyWindow(_window)
    renderer._initialized = false

    return nothing

end


function render!(renderer::Renderer, draw::Function, draw_args...)

    @unpack _window, _initialized = renderer

    @assert _initialized "Renderer not initialized, call init! before render!"

    try
        # start the Dear ImGui frame
        ImGui_ImplOpenGL3_NewFrame()
        ImGui_ImplGlfw_NewFrame()
        CImGui.NewFrame()

        #draw the frame
        draw(draw_args...)

        CImGui.Render()
        GLFW.MakeContextCurrent(_window)

        display_w, display_h = GLFW.GetFramebufferSize(_window)
        glViewport(0, 0, display_w, display_h)
        glClear(GL_COLOR_BUFFER_BIT)
        ImGui_ImplOpenGL3_RenderDrawData(CImGui.GetDrawData())

        GLFW.MakeContextCurrent(_window)
        GLFW.SwapBuffers(_window)
        GLFW.PollEvents() #essential to catch window close requests

    catch e

        @error "Error while updating window" exception=e
        Base.show_backtrace(stderr, catch_backtrace())
        shutdown!(renderer)

    end

    @show draw_args

    return nothing

end


function run!(renderer::Renderer, draw::Function, draw_args...)

    renderer._initialized || init!(renderer)

    while !GLFW.WindowShouldClose(renderer._window)
        render!(renderer, draw, draw_args...)
    end

    shutdown!(renderer)

end


function draw_test(value::Real = 1)

    begin
        CImGui.Begin("Hello, world!")  # create a window called "Hello, world!" and append into it.

        CImGui.Text("This is some useful text.")  # display some text
        CImGui.SameLine()
        CImGui.Text("passed value = $value")

        CImGui.Text(@sprintf("Application average %.3f ms/frame (%.1f FPS)", 1000 / CImGui.GetIO().Framerate, CImGui.GetIO().Framerate))

        CImGui.End()
    end

end

function draw_test2(value::Real = 1)

    # show a simple window that we create ourselves.
    # we use a Begin/End pair to created a named window.
    @cstatic f=Cfloat(0.0) begin
        CImGui.Begin("Hello, world!")  # create a window called "Hello, world!" and append into it.
        CImGui.Text("This is some useful text.")  # display some text

        @c CImGui.SliderFloat("float", &f, 0, 1)  # edit 1 float using a #         slider from 0 to 1

        CImGui.End()
    end

end


function draw_test2_nomacros()
    let
        global f_glob = Cfloat(0.0)
        local f = f_glob
        begin
            CImGui.Begin("Hello, world!")
            CImGui.Text("This is some useful text.")
            begin
                f_ref = Ref(f)
                f_return = CImGui.SliderFloat("float", f_ref, 0, 1)
                f = f_ref[]
                f_return
            end
            #= C:\Users\Miguel\.julia\dev\Flight\test.jl:11 =#
            CImGui.End()
        end
        f_glob = f
        f
    end

end

#don't need any static variables. we can modify the input variables directly. to
#achieve this we can do one of the following:
#1) have Refs to widget-compatible types passed to the draw function, and then
#   call the widgets on them directly
#2) have fields of a mutable struct passed to the draw function. for each field variable, we
#   create a Ref, pass it to the widget, and then reassign the de-referenced Ref
#   to the passed variable. this is exactly what the @c macro does
#
function draw_test3(f::Ref{Cfloat})
    begin
        CImGui.Begin("Hello, world!")
        CImGui.Text("This is some useful text.")
        CImGui.SliderFloat("float", f, 0, 1)
        CImGui.End()
    end

end


end #module