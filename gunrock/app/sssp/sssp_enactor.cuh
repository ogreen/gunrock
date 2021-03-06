// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * sssp_enactor.cuh
 *
 * @brief SSSP Problem Enactor
 */

#pragma once

#include <gunrock/util/multithreading.cuh>
#include <gunrock/util/multithread_utils.cuh>
#include <gunrock/util/kernel_runtime_stats.cuh>
#include <gunrock/util/test_utils.cuh>

#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/advance/kernel_policy.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/oprtr/filter/kernel_policy.cuh>
#include <gunrock/priority_queue/kernel.cuh>
#include <gunrock/priority_queue/kernel_policy.cuh>

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/sssp/sssp_problem.cuh>
#include <gunrock/app/sssp/sssp_functor.cuh>


namespace gunrock {
namespace app {
namespace sssp {

    template <typename Problem, bool INSTRUMENT, bool DEBUG, bool SIZE_CHECK> class Enactor;

    template <typename VertexId, typename SizeT, typename Value, SizeT NUM_VERTEX_ASSOCIATES, SizeT NUM_VALUE__ASSOCIATES>
    __global__ void Expand_Incoming_SSSP (
        const SizeT            num_elements,
        const VertexId* const  keys_in,
              VertexId*        keys_out,
        const size_t           array_size,
              char*            array)
    {
        extern __shared__ char s_array[];
        const SizeT STRIDE = gridDim.x * blockDim.x;
        size_t      offset                = 0;
        VertexId** s_vertex_associate_in  = (VertexId**)&(s_array[offset]);
        offset+=sizeof(VertexId*) * NUM_VERTEX_ASSOCIATES;
        Value**    s_value__associate_in  = (Value**   )&(s_array[offset]);
        offset+=sizeof(Value*   ) * NUM_VALUE__ASSOCIATES;
        VertexId** s_vertex_associate_org = (VertexId**)&(s_array[offset]);
        offset+=sizeof(VertexId*) * NUM_VERTEX_ASSOCIATES;
        Value**    s_value__associate_org = (Value**   )&(s_array[offset]);
        SizeT x = threadIdx.x;
        if (x < array_size)
        {
            s_array[x]=array[x];
            x+=blockDim.x; 
        }
        __syncthreads();

        x = blockIdx.x * blockDim.x + threadIdx.x;

        while (x<num_elements)
        {
            VertexId key=keys_in[x];
            Value t=s_value__associate_in[0][x];

            Value old_value = atomicMin(s_value__associate_org[0]+key, t);
            if (old_value<=t)
            {
                keys_out[x]=-1;
                x+=STRIDE;
                continue;
            }

            keys_out[x]=key;

            #pragma unrool
            for (SizeT i=1;i<NUM_VALUE__ASSOCIATES;i++)
                s_value__associate_org[i][key]=s_value__associate_in[i][x];
            #pragma unrool
            for (SizeT i=0;i<NUM_VERTEX_ASSOCIATES;i++)
                s_vertex_associate_org[i][key]=s_vertex_associate_in[i][x];
            x+=STRIDE;
        }
    }

template <
    typename AdvanceKernelPolicy,
    typename FilterKernelPolicy,
    typename Enactor>
struct SSSPIteration : public IterationBase <
    AdvanceKernelPolicy, FilterKernelPolicy, Enactor,
    true, false, false, true, Enactor::Problem::MARK_PATHS>
{
    typedef typename Enactor::SizeT      SizeT     ;    
    typedef typename Enactor::Value      Value     ;    
    typedef typename Enactor::VertexId   VertexId  ;
    typedef typename Enactor::Problem    Problem ;
    typedef typename Problem::DataSlice  DataSlice ;
    typedef GraphSlice<SizeT, VertexId, Value> GraphSlice;
    typedef SSSPFunctor<VertexId, SizeT, Value, Problem> SsspFunctor;

    static void SubQueue_Core(
        int                            thread_num,
        int                            peer_,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        util::Array1D<SizeT, SizeT>   *scanned_edges,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        DataSlice                     *data_slice,
        DataSlice                     *d_data_slice,
        GraphSlice                    *graph_slice,
        util::CtaWorkProgressLifetime *work_progress,
        ContextPtr                     context,
        cudaStream_t                   stream)
    {
        if (Enactor::DEBUG) util::cpu_mt::PrintMessage("Advance begin",thread_num, enactor_stats->iteration);
        frontier_attribute->queue_reset = true;

        // Edge Map
        gunrock::oprtr::advance::LaunchKernel<AdvanceKernelPolicy, Problem, SsspFunctor>(
            enactor_stats[0],
            frontier_attribute[0],
            d_data_slice,
            (VertexId*)NULL,
            (bool*)    NULL,
            (bool*)    NULL,
            scanned_edges ->GetPointer(util::DEVICE),
            frontier_queue->keys[frontier_attribute->selector]  .GetPointer(util::DEVICE), // d_in_queue
            frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE), // d_out_queue
            (VertexId*)NULL,
            (VertexId*)NULL,
            graph_slice->row_offsets   .GetPointer(util::DEVICE),
            graph_slice->column_indices.GetPointer(util::DEVICE),
            (SizeT*)   NULL,
            (VertexId*)NULL,
            graph_slice->nodes, // max_in_queue
            graph_slice->edges, // max_out_queue
            work_progress[0],
            context[0],
            stream,
            gunrock::oprtr::advance::V2V,
            false,
            false);

        frontier_attribute->queue_reset = false;
        frontier_attribute->queue_index++;
        frontier_attribute->selector ^= 1;
        enactor_stats     -> Accumulate(
            work_progress -> GetQueueLengthPointer<unsigned int, SizeT>(frontier_attribute->queue_index), stream);

        if (Enactor::DEBUG) util::cpu_mt::PrintMessage("Advance end", thread_num, enactor_stats->iteration, peer_);

        //Vertex Map
        gunrock::oprtr::filter::Kernel<FilterKernelPolicy, Problem, SsspFunctor>
            <<<enactor_stats->filter_grid_size, FilterKernelPolicy::THREADS, 0, stream>>>(
            enactor_stats->iteration+1,
            frontier_attribute->queue_reset,
            frontier_attribute->queue_index,
            frontier_attribute->queue_length,
            frontier_queue->keys[frontier_attribute->selector  ].GetPointer(util::DEVICE),      // d_in_queue
            NULL,                                                                  // d_pred_in_queue
            frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),     // d_out_queue
            d_data_slice,
            NULL,
            work_progress[0],
            frontier_queue->keys[frontier_attribute->selector  ].GetSize(), // max_in_queue
            frontier_queue->keys[frontier_attribute->selector^1].GetSize(), // max_out_queue
            enactor_stats->filter_kernel_stats);
        
        if (Enactor::DEBUG && (enactor_stats->retval = util::GRError("filter_forward::Kernel failed", __FILE__, __LINE__))) return;
        if (Enactor::DEBUG) util::cpu_mt::PrintMessage("Filter end.", thread_num, enactor_stats->iteration, peer_);

        //TODO: split the output queue into near/far pile, put far pile in far queue, put near pile as the input queue
        //for next round.
        /*out_length = 0;
        if (frontier_attribute->queue_length > 0) {
            out_length = gunrock::priority_queue::Bisect
                <PriorityQueueKernelPolicy, SSSPProblem, NearFarPriorityQueue, PqFunctor>(
                (int*)graph_slice->frontier_queues[peer_].keys[frontier_attribute->selector].GetPointer(util::DEVICE),
                pq,
                (unsigned int)frontier_attribute->queue_length,
                d_data_slice,
                graph_slice->frontier_queues[peer_].keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),
                pq->queue_length,
                pq_level,
                (pq_level+1),
                context[0],
                graph_slice->nodes);
            //printf("out:%d, pq_length:%d\n", out_length, pq->queue_length);
            if (retval = work_progress->SetQueueLength(frontier_attribute->queue_index, out_length)) break;
        }
        //
        //If the output queue is empty and far queue is not, then add priority level and split the far pile.
        if ( out_length == 0 && pq->queue_length > 0) {
            while (pq->queue_length > 0 && out_length == 0) {
                pq->selector ^= 1;
                pq_level++;
                out_length = gunrock::priority_queue::Bisect
                    <PriorityQueueKernelPolicy, SSSPProblem, NearFarPriorityQueue, PqFunctor>(
                    (int*)pq->nf_pile[0]->d_queue[pq->selector^1],
                    pq,
                    (unsigned int)pq->queue_length,
                    d_data_slice,
                    graph_slice->frontier_queues[peer_].keys[frontier_attribute->selector^1],
                    0,
                    pq_level,
                    (pq_level+1),
                    context[0],
                    graph_slice->nodes);
                //printf("out after p:%d, pq_length:%d\n", out_length, pq->queue_length);
                if (out_length > 0) {
                    if (retval = work_progress->SetQueueLength(frontier_attribute->queue_index, out_length)) break;
                }
            }
        }
        */

        frontier_attribute->queue_index++;
        frontier_attribute->selector ^= 1;

        if (data_slice->num_gpus == 1)
        {
            util::MemsetKernel<<<128, 128, 0, stream>>> (data_slice -> sssp_marker.GetPointer(util::DEVICE), (int)0, graph_slice->nodes);
        }
    }

    template <int NUM_VERTEX_ASSOCIATES, int NUM_VALUE__ASSOCIATES>
    static void Expand_Incoming(
              int             grid_size,
              int             block_size,
              size_t          shared_size,
              cudaStream_t    stream,
              SizeT           &num_elements,
              VertexId*       keys_in,
        util::Array1D<SizeT, VertexId>*       keys_out,
        const size_t          array_size,
              char*           array,
              DataSlice*      data_slice)
    {
        bool over_sized = false;
        Check_Size<Enactor::SIZE_CHECK, SizeT, VertexId>(
            "queue1", num_elements, keys_out, over_sized, -1, -1, -1);
        Expand_Incoming_SSSP
            <VertexId, SizeT, Value, NUM_VERTEX_ASSOCIATES, NUM_VALUE__ASSOCIATES>
            <<<grid_size, block_size, shared_size, stream>>> (
            num_elements,
            keys_in,
            keys_out->GetPointer(util::DEVICE),
            array_size,
            array);
    }

    static cudaError_t Compute_OutputLength(
        FrontierAttribute<SizeT> *frontier_attribute,
        SizeT       *d_offsets,
        VertexId    *d_indices,
        VertexId    *d_in_key_queue,
        util::Array1D<SizeT, SizeT>       *partitioned_scanned_edges,
        SizeT        max_in,
        SizeT        max_out,
        CudaContext                    &context,
        cudaStream_t                   stream,
        gunrock::oprtr::advance::TYPE  ADVANCE_TYPE,
        bool                           express = false)
    {
        cudaError_t retval = cudaSuccess;
        bool over_sized = false;
        if (retval = Check_Size<Enactor::SIZE_CHECK, SizeT, SizeT> (
            "scanned_edges", frontier_attribute->queue_length, partitioned_scanned_edges, over_sized, -1, -1, -1, false)) return retval;
        retval = gunrock::oprtr::advance::ComputeOutputLength
            <AdvanceKernelPolicy, Problem, SsspFunctor>(
            frontier_attribute,
            d_offsets,
            d_indices,
            d_in_key_queue,
            partitioned_scanned_edges->GetPointer(util::DEVICE),
            max_in,
            max_out,
            context,
            stream,
            ADVANCE_TYPE,
            express);
        return retval;
    }

    template <
        int NUM_VERTEX_ASSOCIATES,
        int NUM_VALUE__ASSOCIATES>
    static void Make_Output(
        int                            thread_num,
        SizeT                          num_elements,
        int                            num_gpus,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        util::Array1D<SizeT, SizeT>   *scanned_edges,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        util::Array1D<SizeT, DataSlice>
                                      *data_slice_,
        GraphSlice                    *graph_slice,
        util::CtaWorkProgressLifetime *work_progress,
        ContextPtr                     context,
        cudaStream_t                   stream)
    {
        typedef  IterationBase<AdvanceKernelPolicy, FilterKernelPolicy, Enactor, 
            true, false, false, true, Enactor::Problem::MARK_PATHS> BaseEnactor;
        util::MemsetKernel<<<128, 128, 0, stream>>> (data_slice_[0]->sssp_marker.GetPointer(util::DEVICE), (int)0, graph_slice->nodes);
        BaseEnactor::template Make_Output < NUM_VERTEX_ASSOCIATES, NUM_VALUE__ASSOCIATES> (
            thread_num, num_elements, num_gpus,
            frontier_queue, scanned_edges, frontier_attribute,
            enactor_stats, data_slice_, graph_slice, work_progress, context, stream);
    }

    static void Check_Queue_Size(
        int                            thread_num,
        int                            peer_,
        SizeT                          request_length,
        util::DoubleBuffer<SizeT, VertexId, Value>
                                      *frontier_queue,
        FrontierAttribute<SizeT>      *frontier_attribute,
        EnactorStats                  *enactor_stats,
        GraphSlice                    *graph_slice
        )    
    {    
        bool over_sized = false;
        int  selector   = frontier_attribute->selector;
        int  iteration  = enactor_stats -> iteration;

        if (Enactor::DEBUG)
            printf("%d\t %d\t %d\t queue_length = %d, output_length = %d\n",
                thread_num, iteration, peer_,
                frontier_queue->keys[selector^1].GetSize(),
                request_length);fflush(stdout);

        if (enactor_stats->retval = 
            Check_Size<true, SizeT, VertexId > ("queue3", request_length, &frontier_queue->keys  [selector^1], over_sized, thread_num, iteration, peer_, false)) return; 
        if (enactor_stats->retval = 
            Check_Size<true, SizeT, VertexId > ("queue3", graph_slice->nodes+2, &frontier_queue->keys  [selector  ], over_sized, thread_num, iteration, peer_, true )) return; 
        if (Problem::USE_DOUBLE_BUFFER)
        {    
            if (enactor_stats->retval = 
                Check_Size<true, SizeT, Value> ("queue3", request_length, &frontier_queue->values[selector^1], over_sized, thread_num, iteration, peer_, false)) return; 
            if (enactor_stats->retval = 
                Check_Size<true, SizeT, Value> ("queue3", graph_slice->nodes+2, &frontier_queue->values[selector  ], over_sized, thread_num, iteration, peer_, true )) return; 
        }    
    }
};

    template <
        typename AdvanceKernelPolicy,
        typename FilterKernelPolicy,
        typename Enactor>
    static CUT_THREADPROC SSSPThread(
        void * thread_data_)
    {
        typedef typename Enactor::Problem    Problem;
        typedef typename Enactor::SizeT      SizeT     ;   
        typedef typename Enactor::VertexId   VertexId  ;
        typedef typename Enactor::Value      Value     ;   
        typedef typename Problem::DataSlice     DataSlice ;
        typedef GraphSlice<SizeT, VertexId, Value>    GraphSlice;
        typedef SSSPFunctor<VertexId, SizeT, Value, Problem> Functor;
        ThreadSlice  *thread_data        =  (ThreadSlice*) thread_data_;
        Problem      *problem            =  (Problem*)     thread_data->problem;
        Enactor   *enactor            =  (Enactor*)  thread_data->enactor;
        int           num_gpus           =   problem     -> num_gpus;
        int           thread_num         =   thread_data -> thread_num;
        int           gpu_idx            =   problem     -> gpu_idx            [thread_num] ;
        DataSlice    *data_slice         =   problem     -> data_slices        [thread_num].GetPointer(util::HOST);
        FrontierAttribute<SizeT>
                     *frontier_attribute = &(enactor     -> frontier_attribute [thread_num * num_gpus]);
        EnactorStats *enactor_stats      = &(enactor     -> enactor_stats      [thread_num * num_gpus]);

        do {
            if (enactor_stats[0].retval = util::SetDevice(gpu_idx)) break;
            thread_data->stats = 1;
            while (thread_data->stats != 2) sleep(0);
            thread_data->stats = 3;

            for (int peer_=0;peer_<num_gpus;peer_++)
            {
                frontier_attribute[peer_].queue_index  = 0;        // Work queue index
                frontier_attribute[peer_].queue_length = peer_==0?thread_data->init_size:0; 
                frontier_attribute[peer_].selector     = 0;//frontier_attrbute[peer_].queue_length == 0 ? 0 : 1;
                frontier_attribute[peer_].queue_reset  = true;
                enactor_stats     [peer_].iteration    = 0;
            }

            gunrock::app::Iteration_Loop
                <Problem::MARK_PATHS? 1:0, 1, Enactor, Functor, SSSPIteration<AdvanceKernelPolicy, FilterKernelPolicy, Enactor> > (thread_data);
            printf("SSSP_Thread finished\n");fflush(stdout);

        } while(0);

        thread_data->stats=4;
        CUT_THREADEND;
    }

/**
 * @brief SSSP problem enactor class.
 *
 * @tparam INSTRUMWENT Boolean type to show whether or not to collect per-CTA clock-count statistics
 */
template<typename _Problem, bool _INSTRUMENT, bool _DEBUG, bool _SIZE_CHECK>
class SSSPEnactor : public EnactorBase<typename _Problem::SizeT, _DEBUG, _SIZE_CHECK>
{
    _Problem     *problem      ;
    ThreadSlice  *thread_slices;// = new ThreadSlice [this->num_gpus];
    CUTThread    *thread_Ids   ;// = new CUTThread   [this->num_gpus];

public:
    typedef _Problem                   Problem;
    typedef typename Problem::SizeT    SizeT   ;
    typedef typename Problem::VertexId VertexId;
    typedef typename Problem::Value    Value   ;
    static const bool INSTRUMENT = _INSTRUMENT;
    static const bool DEBUG      = _DEBUG;
    static const bool SIZE_CHECK = _SIZE_CHECK;

    /**
     * @brief BFSEnactor constructor
     */
    SSSPEnactor(int num_gpus = 1, int* gpu_idx = NULL) :
        EnactorBase<SizeT, _DEBUG, _SIZE_CHECK>(VERTEX_FRONTIERS, num_gpus, gpu_idx)//,
    {
        thread_slices = NULL;
        thread_Ids    = NULL;
        problem       = NULL;
    }

    /**
     * @brief BFSEnactor destructor
     */
    virtual ~SSSPEnactor()
    {
        cutWaitForThreads(thread_Ids, this->num_gpus);
        delete[] thread_Ids   ; thread_Ids    = NULL;
        delete[] thread_slices; thread_slices = NULL;
        problem = NULL;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Obtain statistics about the last SSSP search enacted.
     *
     * @param[out] total_queued Total queued elements in SSSP kernel running.
     * @param[out] search_depth Search depth of SSSP algorithm.
     * @param[out] avg_duty Average kernel running duty (kernel run time/kernel lifetime).
     */
    template <typename VertexId>
    void GetStatistics(
        long long &total_queued,
        VertexId  &search_depth,
        double    &avg_duty)
    {   
        unsigned long long total_lifetimes=0;
        unsigned long long total_runtimes =0; 
        total_queued = 0;
        search_depth = 0;
        for (int gpu=0;gpu<this->num_gpus;gpu++)
        {   
            if (this->num_gpus!=1)
                if (util::SetDevice(this->gpu_idx[gpu])) return;
            cudaThreadSynchronize();

            for (int peer=0; peer< this->num_gpus; peer++)
            {   
                EnactorStats *enactor_stats_ = this->enactor_stats + gpu * this->num_gpus + peer;
                enactor_stats_ -> total_queued.Move(util::DEVICE, util::HOST);
                total_queued += enactor_stats_ -> total_queued[0];
                if (enactor_stats_ -> iteration > search_depth) 
                    search_depth = enactor_stats_ -> iteration;
                total_lifetimes += enactor_stats_ -> total_lifetimes;
                total_runtimes  += enactor_stats_ -> total_runtimes;
            } 
        }   
        avg_duty = (total_lifetimes >0) ?
            double(total_runtimes) / total_lifetimes : 0.0;
    }

    template<
        typename AdvanceKernelPolicy,
        typename FilterKernelPolicy>
    cudaError_t InitSSSP(
        ContextPtr  *context,
        Problem     *problem,
        int         max_grid_size = 0,
        bool        size_check    = true)
    {
        cudaError_t retval = cudaSuccess;

        // Lazy initialization
        if (retval = EnactorBase<SizeT, DEBUG, SIZE_CHECK>::Init(problem,
                                       max_grid_size,
                                       AdvanceKernelPolicy::CTA_OCCUPANCY,
                                       FilterKernelPolicy::CTA_OCCUPANCY)) return retval;

        this->problem = problem;
        thread_slices = new ThreadSlice [this->num_gpus];
        thread_Ids    = new CUTThread   [this->num_gpus];

        /*for (int gpu=0;gpu<this->num_gpus;gpu++)
        {
            if (retval = util::SetDevice(this->gpu_idx[gpu])) break;
            if (BFSProblem::ENABLE_IDEMPOTENCE) {
                int bytes = (problem->graph_slices[gpu]->nodes + 8 - 1) / 8;
                cudaChannelFormatDesc   bitmask_desc = cudaCreateChannelDesc<char>();
                gunrock::oprtr::filter::BitmaskTex<unsigned char>::ref.channelDesc = bitmask_desc;
                if (retval = util::GRError(cudaBindTexture(
                    0,
                    gunrock::oprtr::filter::BitmaskTex<unsigned char>::ref,//ts_bitmask[gpu],
                    problem->data_slices[gpu]->visited_mask.GetPointer(util::DEVICE),
                    bytes),
                    "BFSEnactor cudaBindTexture bitmask_tex_ref failed", __FILE__, __LINE__)) break;
            }
        }*/

        for (int gpu=0;gpu<this->num_gpus;gpu++)
        {
            thread_slices[gpu].thread_num    = gpu;
            thread_slices[gpu].problem       = (void*)problem;
            thread_slices[gpu].enactor       = (void*)this;
            thread_slices[gpu].context       = &(context[gpu*this->num_gpus]);
            thread_slices[gpu].stats         = -1;
            thread_slices[gpu].thread_Id     = cutStartThread(
                    (CUT_THREADROUTINE)&(SSSPThread<
                        AdvanceKernelPolicy, FilterKernelPolicy,
                        SSSPEnactor<Problem, INSTRUMENT, DEBUG, SIZE_CHECK> >),
                    (void*)&(thread_slices[gpu]));
            thread_Ids[gpu] = thread_slices[gpu].thread_Id;
        }

       return retval;
    }

    cudaError_t Reset()
    {
        return EnactorBase<SizeT, DEBUG, SIZE_CHECK>::Reset();
    }
 
    /** @} */

    /**
     * @brief SSSP Enact kernel entry.
     *
     * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
     * @tparam FilterKernelPolicy Kernel policy for filter operator.
     * @tparam SSSPProblem SSSP Problem type.
     *
     * @param[in] context CudaContext pointer for moderngpu APIs
     * @param[in] problem SSSPProblem object.
     * @param[in] src Source node for SSSP.
     * @param[in] queue_sizing Scaling factor for frontier queue
     * @param[in] max_grid_size Max grid size for SSSP kernel calls.
     *
     * \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    template<
        typename AdvanceKernelPolicy,
        typename FilterKernelPolicy>
    cudaError_t EnactSSSP(
        VertexId       src)
    {
        clock_t      start_time = clock();
        cudaError_t  retval     = cudaSuccess;
        
        /*typedef PQFunctor<
            VertexId,
            SizeT,
            SSSPProblem> PqFunctor;

        typedef gunrock::priority_queue::PriorityQueue<
            VertexId,
            SizeT> NearFarPriorityQueue;

        typedef gunrock::priority_queue::KernelPolicy<
            SSSPProblem,                        // Problem data type
            300,                                // CUDA_ARCH
            INSTRUMENT,                         // INSTRUMENT
            8,                                  // MIN_CTA_OCCUPANCY
            10>                                 // LOG_THREADS
            PriorityQueueKernelPolicy;

        NearFarPriorityQueue *pq = new NearFarPriorityQueue;
        util::GRError(
            pq->Init(problem->graph_slices[0]->edges, queue_sizing),
            "Priority Queue SSSP Initialization Failed", __FILE__, __LINE__);*/

        do {
            for (int gpu=0;gpu<this->num_gpus;gpu++)
            {
                if ((this->num_gpus ==1) || (gpu==this->problem->partition_tables[0][src]))
                     thread_slices[gpu].init_size=1;
                else thread_slices[gpu].init_size=0;
                this->frontier_attribute[gpu*this->num_gpus].queue_length = thread_slices[gpu].init_size;
            }

            for (int gpu=0; gpu< this->num_gpus; gpu++)
            {
                while (thread_slices[gpu].stats!=1) sleep(0);
                thread_slices[gpu].stats=2;
            }
            for (int gpu=0; gpu< this->num_gpus; gpu++)
            {
                while (thread_slices[gpu].stats!=4) sleep(0);
            }

            for (int gpu=0;gpu<this->num_gpus;gpu++)
            if (this->enactor_stats[gpu].retval!=cudaSuccess) {retval=this->enactor_stats[gpu].retval;break;}
        } while(0);

        if (this->DEBUG) printf("\nGPU SSSP Done.\n");
        return retval;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    typedef gunrock::oprtr::filter::KernelPolicy<
        Problem,                            // Problem data type
        300,                                // CUDA_ARCH
        INSTRUMENT,                         // INSTRUMENT
        0,                                  // SATURATION QUIT
        true,                               // DEQUEUE_PROBLEM_SIZE
        8,                                  // MIN_CTA_OCCUPANCY
        8,                                  // LOG_THREADS
        1,                                  // LOG_LOAD_VEC_SIZE
        0,                                  // LOG_LOADS_PER_TILE
        5,                                  // LOG_RAKING_THREADS
        5,                                  // END_BITMASK_CULL
        8>                                  // LOG_SCHEDULE_GRANULARITY
    FilterKernelPolicy;

    typedef gunrock::oprtr::advance::KernelPolicy<
        Problem,                            // Problem data type
        300,                                // CUDA_ARCH
        INSTRUMENT,                         // INSTRUMENT
        8,                                  // MIN_CTA_OCCUPANCY
        7,                                  // LOG_THREADS
        10,                                 // LOG_BLOCKS
        32*128,                             // LIGHT_EDGE_THRESHOLD
        1,                                  // LOG_LOAD_VEC_SIZE
        1,                                  // LOG_LOADS_PER_TILE
        5,                                  // LOG_RAKING_THREADS
        32,                                 // WARP_GATHER_THRESHOLD
        128 * 4,                            // CTA_GATHER_THRESHOLD
        7,                                  // LOG_SCHEDULE_GRANULARITY
        gunrock::oprtr::advance::TWC_FORWARD>
    FWDAdvanceKernelPolicy;

    typedef gunrock::oprtr::advance::KernelPolicy<
        Problem,                            // Problem data type
        300,                                // CUDA_ARCH
        INSTRUMENT,                         // INSTRUMENT
        1,                                  // MIN_CTA_OCCUPANCY
        10,                                 // LOG_THREADS
        8,                                  // LOG_BLOCKS
        32*1024,                            // LIGHT_EDGE_THRESHOLD
        1,                                  // LOG_LOAD_VEC_SIZE
        0,                                  // LOG_LOADS_PER_TILE
        5,                                  // LOG_RAKING_THREADS
        32,                                 // WARP_GATHER_THRESHOLD
        128 * 4,                            // CTA_GATHER_THRESHOLD
        7,                                  // LOG_SCHEDULE_GRANULARITY
        gunrock::oprtr::advance::LB>
    LBAdvanceKernelPolicy;

    /**
     * @brief SSSP Enact kernel entry.
     *
     * @tparam SSSPProblem SSSP Problem type. @see SSSPProblem
     *
     * @param[in] src Source node for SSSP.
     *
     * \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    //template <typename SSSPProblem>
    cudaError_t Enact(
        VertexId     src,
        int traversal_mode = 0)
    {
        int min_sm_version = -1;
        for (int i=0;i<this->num_gpus;i++)
            if (min_sm_version == -1 || this->cuda_props[i].device_sm_version < min_sm_version)
                min_sm_version = this->cuda_props[i].device_sm_version;

        if (min_sm_version >= 300) {
            if (traversal_mode == 0)
                return EnactSSSP< LBAdvanceKernelPolicy, FilterKernelPolicy>(src);
            else
                return EnactSSSP<FWDAdvanceKernelPolicy, FilterKernelPolicy>(src);
        }

        //to reduce compile time, get rid of other architecture for now
        //TODO: add all the kernelpolicy settings for all archs
        printf("Not yet tuned for this architecture\n");
        return cudaErrorInvalidDeviceFunction;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief SSSP Enact kernel entry.
     *
     * @param[in] context CudaContext pointer for moderngpu APIs
     * @param[in] problem Pointer to SSSPProblem object.
     * @param[in] traversal_mode Load-balanced or Dynamic cooperative
     * @param[in] max_grid_size Max grid size for SSSP kernel calls.
     *
     * \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    cudaError_t Init(
        ContextPtr   *context,
        Problem      *problem,
        int          max_grid_size = 0,
        bool         size_check = true,
        int          traversal_mode = 0)
    {
        int min_sm_version = -1;
        for (int i=0;i<this->num_gpus;i++)
            if (min_sm_version == -1 || this->cuda_props[i].device_sm_version < min_sm_version)
                min_sm_version = this->cuda_props[i].device_sm_version;

        if (min_sm_version >= 300) {
            if (traversal_mode == 0)
                return InitSSSP< LBAdvanceKernelPolicy, FilterKernelPolicy>(
                    context, problem, max_grid_size, size_check);
            else
                return InitSSSP<FWDAdvanceKernelPolicy, FilterKernelPolicy>(
                    context, problem, max_grid_size, size_check);
        }

        //to reduce compile time, get rid of other architecture for now
        //TODO: add all the kernelpolicy settings for all archs
        printf("Not yet tuned for this architecture\n");
        return cudaErrorInvalidDeviceFunction;
    }


    /** @} */

};

} // namespace sssp
} // namespace app
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
