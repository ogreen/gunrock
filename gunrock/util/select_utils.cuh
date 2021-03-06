// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * select_utils.cuh
 *
 * @brief kenel utils used in minimum spanning tree algorithm.
 */

#pragma once
#include <cub/cub.cuh>

namespace gunrock {
namespace util {

    /**
     * \addtogroup PublicInterface
     * @{
     */

    //---------------------------------------------------------------------
    // Globals, constants and typedefs
    //---------------------------------------------------------------------
    struct GreaterThan
    {
	int compare;

	__host__ __device__ __forceinline__
	GreaterThan(int compare) : compare(compare) { }

	__host__ __device__ __forceinline__
	bool operator()(const int &a) const { return (a > compare); }
    };

    /**
     * @brief selects items from from a sequence of int keys using a
     * section functor (greater-than)
     *
     */
    template <typename VertexId, typename SizeT>
    cudaError_t CUBSelect(
	VertexId  *d_input,
	SizeT     num_elements,
	VertexId  *d_output,
	unsigned int *num_selected)
    {
	cudaError_t retval = cudaSuccess;

	/*
	  VertexId *input  = NULL;
	  VertexId *output = NULL;

	  if (util::GRError((retval = cudaMalloc(
	  &input, sizeof(VertexId)*d_num_elements)),
	  "CUBSelect input malloc failed",
	  __FILE__, __LINE__)) return retval;
	  if (util::GRError((retval = cudaMalloc(
	  &output, sizeof(VertexId)*d_num_elements)),
	  "CUBSelect output malloc failed",
	  __FILE__, __LINE__)) return retval;

	  cub::DoubleBuffer<VertexId> d_input_buffer(d_input, input);
	  cub::DoubleBuffer<VertexId> d_output_buffer(d_output, output);
	*/

	unsigned int *d_num_selected = NULL;
	if (util::GRError((retval = cudaMalloc(
	    (void**)&d_num_selected, sizeof(unsigned int))),
	    "CUBSelect d_num_selected malloc failed",
	    __FILE__, __LINE__)) return retval;

	void  *d_temp_storage = NULL;
	size_t temp_storage_bytes = 0;
	GreaterThan select_op(-1);

	// determine temporary device storage requirements
	if (util::GRError((retval = cub::DeviceSelect::If(
	    d_temp_storage,
	    temp_storage_bytes,
	    d_input,
	    d_output,
	    d_num_selected,
	    num_elements,
	    select_op)),
	    "CUBSelect cub::DeviceSelect::If failed",
	    __FILE__, __LINE__)) return retval;

	// allocate temporary storage
	if (util::GRError((retval = cudaMalloc(
	    &d_temp_storage, temp_storage_bytes)),
	    "CUBSelect malloc d_temp_storage failed",
	    __FILE__, __LINE__)) return retval;

	// run selection
	if (util::GRError((retval = cub::DeviceSelect::If(
	    d_temp_storage,
	    temp_storage_bytes,
	    d_input,
	    d_output,
	    d_num_selected,
	    num_elements,
	    select_op)),
            "CUBSelect cub::DeviceSelect::If failed",
            __FILE__, __LINE__)) return retval;

	/*
	// copy back output
	if (util::GRError((retval = cudaMemcpy(
	d_output,
	d_output_buffer.Current(),
	sizeof(VertexId)*(*d_num_selected),
	cudaMemcpyDeviceToDevice)),
	"CUBSelect copy back output failed",
	__FILE__, __LINE__)) return retval;
	*/

	if (util::GRError((retval = cudaMemcpy(
	    num_selected,
	    d_num_selected,
	    sizeof(unsigned int),
	    cudaMemcpyDeviceToHost)),
	    "CUBSelect copy back num_selected failed",
	    __FILE__, __LINE__)) return retval;

	// clean up
	if (util::GRError((retval = cudaFree(d_temp_storage)),
	    "CUBSelect free d_temp_storage failed",
	    __FILE__, __LINE__)) return retval;
	if (util::GRError((retval = cudaFree(d_num_selected)),
            "CUBSelect free d_num_selected failed",
	    __FILE__, __LINE__)) return retval;

	/*
	  if (util::GRError((retval = cudaFree(input)),
	  "CUBSelect free input failed",
	  __FILE__, __LINE__)) return retval;
	  if (util::GRError((retval = cudaFree(output)),
	  "CUBSelect free output failed",
	  __FILE__, __LINE__)) return retval;
	*/

	return retval;
    }

    /** @} */

} //util
} //gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
