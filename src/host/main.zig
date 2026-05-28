const std = @import("std");
const glfw = @import("glfw");

pub fn main() !void {
    if (glfw.glfwInit() == glfw.GLFW_FALSE) return error.GlfwInitFailed;
    defer glfw.glfwTerminate();

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);

    const window = glfw.glfwCreateWindow(1024, 768, "marauder", null, null) orelse return error.WindowCreationFailed;
    defer glfw.glfwDestroyWindow(window);

    std.debug.print("marauder host started\n", .{});

    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        glfw.glfwPollEvents();
    }
}
