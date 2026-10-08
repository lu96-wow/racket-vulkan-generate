#include <vulkan/vulkan_core.h>
#include <stdio.h>
#define P(T) printf("%-45s %zu\n", #T, sizeof(T))
int main(){
 P(VkApplicationInfo); P(VkInstanceCreateInfo);
 P(VkPhysicalDeviceProperties); P(VkPhysicalDeviceLimits); P(VkPhysicalDeviceSparseProperties);
 P(VkPhysicalDeviceMemoryProperties); P(VkPhysicalDeviceFeatures);
 P(VkClearColorValue); P(VkClearDepthStencilValue);
 P(VkVertexInputBindingDescription); P(VkVertexInputAttributeDescription);
 P(VkPipelineVertexInputStateCreateInfo); P(VkAttachmentDescription);
 P(VkDescriptorSetLayoutBinding); P(VkDescriptorPoolSize);
 P(VkGraphicsPipelineCreateInfo); P(VkComputePipelineCreateInfo);
 P(VkSubmitInfo); P(VkPresentInfoKHR); P(VkSwapchainCreateInfoKHR);
 P(VkImageCreateInfo); P(VkBufferCreateInfo);
 P(VkExtent3D); P(VkViewport); P(VkRect2D);
 P(VkSpecializationInfo); P(VkPipelineShaderStageCreateInfo);
 P(VkDebugUtilsMessengerCreateInfoEXT); P(VkBaseInStructure); P(VkBaseOutStructure);
 return 0;
}
