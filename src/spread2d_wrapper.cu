#include <helper_cuda.h>
#include <iostream>
#include <iomanip>
// idriven coarse grained
#include <thrust/sort.h>
#include <thrust/execution_policy.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/device_vector.h>
#include <thrust/gather.h>

// try another library cub
#include <cub/device/device_radix_sort.cuh>

#include <cuComplex.h>
#include "spread.h"

using namespace std;

int cnufft_allocgpumemory(int nf1, int nf2, int M, int* fw_width, CPX* h_fw, gpuComplex** d_fw, 
                          FLT *h_kx, FLT **d_kx, FLT* h_ky, FLT** d_ky, 
                          CPX *h_c, gpuComplex **d_c)
{
	checkCudaErrors(cudaMalloc(d_kx,M*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(d_ky,M*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(d_c,M*sizeof(gpuComplex)));
	
	size_t pitch;
	checkCudaErrors(cudaMallocPitch((void**) d_fw, &pitch,nf1*sizeof(gpuComplex),nf2));
	*fw_width = pitch/sizeof(gpuComplex);

	return 0;
}

int cnufft_copycpumem_to_gpumem(int nf1, int nf2, int M, int fw_width, CPX* h_fw, gpuComplex* d_fw,
                                FLT *h_kx, FLT *d_kx, FLT* h_ky, FLT* d_ky,
                                CPX *h_c, gpuComplex *d_c)
{
	checkCudaErrors(cudaMemcpy(d_kx,h_kx,M*sizeof(FLT),cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(d_ky,h_ky,M*sizeof(FLT),cudaMemcpyHostToDevice));
	checkCudaErrors(cudaMemcpy(d_c,h_c,M*sizeof(gpuComplex),cudaMemcpyHostToDevice));
	
	return 0;
}

int cnufft_copygpumem_to_cpumem(int nf1, int nf2, int M, int fw_width, CPX* h_fw, gpuComplex* d_fw,
                                FLT *h_kx, FLT *d_kx, FLT* h_ky, FLT* d_ky,
                                CPX *h_c, gpuComplex *d_c)
{
	checkCudaErrors(cudaMemcpy2D(h_fw,nf1*sizeof(gpuComplex),d_fw,fw_width*sizeof(gpuComplex),
                                     nf1*sizeof(gpuComplex),nf2,cudaMemcpyDeviceToHost));
	
	return 0;
}

void cnufft_free_gpumemory(gpuComplex* d_fw, FLT *d_kx, FLT* d_ky, gpuComplex *d_c)
{
	cudaFree(d_fw);
	cudaFree(d_kx);
	cudaFree(d_ky);
	cudaFree(d_c);
}

int cnufftspread2d_gpu(int nf1, int nf2, CPX* h_fw, int M, FLT *h_kx,
		       FLT *h_ky, CPX *h_c, spread_opts opts)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	
	int ier;
	int fw_width;
	FLT *d_kx,*d_ky;
	gpuComplex *d_c,*d_fw;

	if(opts.pirange){
		for(int i=0; i<M; i++){
			h_kx[i]=RESCALE(h_kx[i], nf1, opts.pirange);
			h_ky[i]=RESCALE(h_ky[i], nf2, opts.pirange);
		}
	}
	cudaEventRecord(start);
	ier = cnufft_allocgpumemory(nf1, nf2, M, &fw_width, h_fw, &d_fw, h_kx, &d_kx, 
                                    h_ky, &d_ky, h_c, &d_c);
#ifdef TIME
  	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	cout<<"[time  ]"<< " Allocating GPU memory " << milliseconds/1000 <<" s"<<endl;
#endif
	cudaEventRecord(start);
	ier = cnufft_copycpumem_to_gpumem(nf1, nf2, M, fw_width, h_fw, d_fw, h_kx, d_kx,
                                          h_ky, d_ky, h_c, d_c);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	cout<<"[time  ]"<< " Copying memory from host to device " << milliseconds/1000 <<" s"<<endl;
#endif

	cudaEventRecord(start);
	switch(opts.method)
        {
                case 1:
                {
                        ier = cnufftspread2d_gpu_idriven(nf1, nf2, fw_width, d_fw, M, d_kx, 
                                                         d_ky, d_c, opts);
                        if(ier != 0 ){
                                cout<<"error: cnufftspread2d_gpu_idriven"<<endl;
                                return 0;
                        }
                }
                break;
                case 2:
                {
                        ier = cnufftspread2d_gpu_idriven_sorted(nf1, nf2, fw_width, d_fw, M, 
                                                                d_kx, d_ky, d_c, opts);
                }
                break;
		case 3:
                {
                        if(nf1 % opts.bin_size_x != 0 || nf2 % opts.bin_size_y !=0){
                                cout << "error: mod(nf1,block_size_x) and mod(nf2,block_size_y) should be 0" << endl;
                                return 0;
                        }
                        ier = cnufftspread2d_gpu_odriven(nf1, nf2, fw_width, d_fw, M, d_kx, 
                                                         d_ky, d_c, opts);
                        if(ier != 0 ){
                                cout<<"error: cnufftspread2d_gpu_odriven"<<endl;
                                return 0;
                        }
                }
                break;
                case 4:
                {
                        ier = cnufftspread2d_gpu_hybrid(nf1, nf2, fw_width, d_fw, M, d_kx, d_ky, d_c, opts);
                        if(ier != 0 ){
                                cout<<"error: cnufftspread2d_gpu_hybrid"<<endl;
                                return 0;
                        }
                }
                break;
                default:
                        cout<<"error: incorrect method, should be 1,2,3 or 4"<<endl;
                        return 0;
        }
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	cout<<"[time  ]"<< " Spread " << milliseconds/1000 <<" s"<<endl;
#endif
	cudaEventRecord(start);
	ier = cnufft_copygpumem_to_cpumem(nf1, nf2, M, fw_width, h_fw, d_fw, h_kx, d_kx,
                                          h_ky, d_ky, h_c, d_c);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	cout<<"[time  ]"<< " Copying memory from device to host " << milliseconds/1000 <<" s"<<endl;
#endif
	cnufft_free_gpumemory(d_fw, d_kx, d_ky, d_c);

	return ier;
}

int cnufftspread2d_gpu_idriven(int nf1, int nf2, int fw_width, gpuComplex* d_fw, int M, FLT *d_kx,
		               FLT *d_ky, gpuComplex *d_c, spread_opts opts)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;

	threadsPerBlock.x = 16;
	threadsPerBlock.y = 1;
	blocks.x = (M + threadsPerBlock.x - 1)/threadsPerBlock.x;
	blocks.y = 1;
	cudaEventRecord(start);
	if(opts.Horner){
		Spread_2d_Idriven_Horner<<<blocks, threadsPerBlock>>>(d_kx, d_ky, d_c, d_fw, M, ns,
			                                              nf1, nf2, es_c, es_beta, fw_width);
	}else{
		Spread_2d_Idriven<<<blocks, threadsPerBlock>>>(d_kx, d_ky, d_c, d_fw, M, ns,
			                                       nf1, nf2, es_c, es_beta, fw_width);
	}

#ifdef SPREADTIME
  	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Idriven \t%.3g ms\n", milliseconds);
#endif
	return 0;
}

int cnufftspread2d_gpu_idriven_sorted(int nf1, int nf2, int fw_width, gpuComplex* d_fw, 
                                      int M, FLT *d_kx, FLT *d_ky, gpuComplex *d_c, 
                                      spread_opts opts)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;

	FLT *d_kxsorted,*d_kysorted;
	gpuComplex *d_csorted;
	int *d_sortidx;

	cudaEventRecord(start);
	checkCudaErrors(cudaMalloc(&d_kxsorted,M*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(&d_kysorted,M*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(&d_csorted,M*sizeof(gpuComplex)));
	checkCudaErrors(cudaMalloc(&d_sortidx,M*sizeof(int)));
#ifdef SPREADTIME
  	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tAllocating GPU memory for sorted array \t%.3g ms\n", milliseconds);
#endif

	cudaEventRecord(start);
	threadsPerBlock.x = 1024;
	threadsPerBlock.y = 1;
	blocks.x = (M + threadsPerBlock.x - 1)/threadsPerBlock.x;
	blocks.y = 1;
	CreateSortIdx<<<blocks, threadsPerBlock>>>(M, nf1, nf2, d_kx, d_ky, d_sortidx);
#ifdef SPRADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tCreateSortIdx \t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	FLT *h_kx, *h_ky;
	CPX *h_c;
	h_kx = (FLT*) malloc(M*sizeof(FLT)); 
	h_ky = (FLT*) malloc(M*sizeof(FLT));
	h_c = (CPX*) malloc(M*sizeof(CPX));
	checkCudaErrors(cudaMemcpy(h_kx, d_kx, M*sizeof(FLT), cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_ky, d_ky, M*sizeof(FLT), cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_c, d_c, M*sizeof(CPX), cudaMemcpyDeviceToHost));
	int* h_sortidx = (int*) malloc(M*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_sortidx,d_sortidx,M*sizeof(int),cudaMemcpyDeviceToHost));
	for(int i=0; i<M; i++){
		printf("sortidx = %d, (x,y) = (%.3g, %.3g), c=(%f, %f)\n", h_sortidx[i], h_kx[i], h_ky[i], h_c[i].real(), h_c[i].imag());
	}
	free(h_sortidx);
#endif 
	if(opts.use_thrust){
		cudaEventRecord(start);
		thrust::counting_iterator<int> iter(0);
		thrust::device_vector<int> indices(M);
		thrust::copy(iter, iter + indices.size(), indices.begin());
		thrust::sort_by_key(thrust::device, d_sortidx, d_sortidx + M, indices.begin());
#ifdef SPREADTIME
		cudaEventRecord(stop);
		cudaEventSynchronize(stop);
  		cudaEventElapsedTime(&milliseconds, start, stop);
		printf("[time  ] \tThrust::sort_by_key \t\t\t%.3g ms\n", milliseconds);
#endif
		cudaEventRecord(start);
		thrust::gather(thrust::device, indices.begin(), indices.end(), d_kx, d_kxsorted);
		thrust::gather(thrust::device, indices.begin(), indices.end(), d_ky, d_kysorted);
		thrust::gather(thrust::device, indices.begin(), indices.end(), d_c, d_csorted);
#ifdef SPREADTIME
		cudaEventRecord(stop);
		cudaEventSynchronize(stop);
  		cudaEventElapsedTime(&milliseconds, start, stop);
		printf("[time  ] \tThrust::gather \t\t\t\t%.3g ms\n", milliseconds);
#endif
	}else{
		cudaEventRecord(start);
		size_t  temp_storage_bytes  = 0;
		void    *d_temp_storage     = NULL;

		int *d_sortedidx;
		checkCudaErrors(cudaMalloc(&d_sortedidx,M*sizeof(int)));
		int *d_index_out, *d_index_in;
		checkCudaErrors(cudaMalloc(&d_index_in,M*sizeof(int)));
		checkCudaErrors(cudaMalloc(&d_index_out,M*sizeof(int)));

		threadsPerBlock.x = 1024;
		threadsPerBlock.y = 1;
		blocks.x = (M + threadsPerBlock.x - 1)/threadsPerBlock.x;
		blocks.y = 1;
		CreateIndex<<<blocks, threadsPerBlock>>>(d_index_in, M);
		//#ifdef TIME
		//
		//cout<<"[time  ]"<< " CreateIndex " << milliseconds <<" s"<<endl;
		//#endif

		cudaEventRecord(start);
		cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, d_sortidx, d_sortedidx, d_index_in, d_index_out, M);
		checkCudaErrors(cudaMalloc(&d_temp_storage,temp_storage_bytes));
		cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, d_sortidx, d_sortedidx, d_index_in, d_index_out, M);

#ifdef SPREADTIME
		cudaEventRecord(stop);
		cudaEventSynchronize(stop);
  		cudaEventElapsedTime(&milliseconds, start, stop);
		printf("[time  ] \tCUB::SortPairs \t\t\t\t%.3g ms\n", milliseconds);
#endif
		cudaEventRecord(start);
		threadsPerBlock.x = 1024;
		threadsPerBlock.y = 1;
		blocks.x = (M + threadsPerBlock.x - 1)/threadsPerBlock.x;
		blocks.y = 1;
		Gather<<<blocks, threadsPerBlock>>>(M, d_index_out, d_kx, d_ky, d_c, d_kxsorted, d_kysorted, d_csorted);
		//thrust::gather(thrust::device, d_index_out, d_index_out+M, d_kx, d_kxsorted);
		//thrust::gather(thrust::device, d_index_out, d_index_out+M, d_ky, d_kysorted);
		//thrust::gather(thrust::device, d_index_out, d_index_out+M, d_c, d_csorted);
#ifdef SPREADTIME
		cudaEventRecord(stop);
		cudaEventSynchronize(stop);
  		cudaEventElapsedTime(&milliseconds, start, stop);
		printf("[time  ] \tKernel (Gather) PtsRearrage \t\t%.3g ms\n", milliseconds);
#endif
	}
#ifdef DEBUG
	checkCudaErrors(cudaMemcpy(h_sortidx,d_sortidx,M*sizeof(int),cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_kx,d_kxsorted,M*sizeof(FLT),cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_ky,d_kysorted,M*sizeof(FLT),cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_c,d_csorted,M*sizeof(gpuComplex),cudaMemcpyDeviceToHost));
	for(int i=0; i<M; i++){
		printf("sortidx = %d, (x,y) = (%.3g, %.3g), c=(%f, %f)\n", h_sortidx[i], h_kx[i], h_ky[i], h_c[i].real(), h_c[i].imag());
	}
#endif 

	cudaEventRecord(start);
	threadsPerBlock.x = 16;
	threadsPerBlock.y = 1;
	blocks.x = (M + threadsPerBlock.x - 1)/threadsPerBlock.x;
	blocks.y = 1;
	Spread_2d_Idriven<<<blocks, threadsPerBlock>>>(d_kxsorted, d_kysorted, d_csorted, d_fw, M, ns,
			nf1, nf2, es_c, es_beta, fw_width);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Idriven \t\t%.3g ms\n", milliseconds);
#endif
	// Free memory
	cudaFree(d_kxsorted);
	cudaFree(d_kysorted);
	cudaFree(d_csorted);
	cudaFree(d_sortidx);
	return 0;
}

int cnufftspread2d_gpu_hybrid(int nf1, int nf2, int fw_width, gpuComplex* d_fw, 
                              int M, FLT *d_kx, FLT *d_ky, gpuComplex *d_c, 
                              spread_opts opts)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;
	int bin_size_x=opts.bin_size_x;
	int bin_size_y=opts.bin_size_y;

	// Parameter setting
	int numbins[2];

	int *d_binsize;
	int *d_binstartpts;
	int *d_sortidx;

	numbins[0] = ceil((FLT) nf1/bin_size_x);
	numbins[1] = ceil((FLT) nf2/bin_size_y);
	// assume that bin_size_x > ns/2;
#ifdef INFO
	cout<<"[info  ] Dividing the uniform grids to bin size["
		<<opts.bin_size_x<<"x"<<opts.bin_size_y<<"]"<<endl;
	cout<<"[info  ] numbins (including ghost bins) = ["
		<<numbins[0]<<"x"<<numbins[1]<<"]"<<endl;
#endif
	FLT *d_kxsorted,*d_kysorted;
	gpuComplex *d_csorted;


	cudaEventRecord(start);
	checkCudaErrors(cudaMalloc(&d_kxsorted,M*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(&d_kysorted,M*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(&d_csorted,M*sizeof(gpuComplex)));

	checkCudaErrors(cudaMalloc(&d_binsize,numbins[0]*numbins[1]*sizeof(int)));
	checkCudaErrors(cudaMalloc(&d_sortidx,M*sizeof(int)));
	checkCudaErrors(cudaMalloc(&d_binstartpts,(numbins[0]*numbins[1]+1)*sizeof(int)));
#ifdef SPREADTIME
  	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tAllocating GPU memory for sorted array \t%.3g ms\n", milliseconds);
#endif

	cudaEventRecord(start);
	checkCudaErrors(cudaMemset(d_binsize,0,numbins[0]*numbins[1]*sizeof(int)));
	CalcBinSize_noghost_2d<<<(M+1024-1)/1024, 1024>>>(M,nf1,nf2,bin_size_x,bin_size_y,
			numbins[0],numbins[1],d_binsize,
			d_kx,d_ky,d_sortidx);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel CalcBinSize_noghost_2d \t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	int *h_binsize;// For debug
	h_binsize     = (int*)malloc(numbins[0]*numbins[1]*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binsize,d_binsize,numbins[0]*numbins[1]*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] bin size:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<" bin["<<setw(3)<<i<<","<<setw(3)<<j<<"]="<<h_binsize[i+j*numbins[0]];
		}
		cout<<endl;
	}
	free(h_binsize);
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif

	cudaEventRecord(start);
	int n=numbins[0]*numbins[1];
	int scanblocksize=1024;
	int numscanblocks=ceil((double)n/scanblocksize);
	int* d_scanblocksum, *d_scanblockstartpts;
#ifdef DEBUG
	printf("[debug ] n=%d, numscanblocks=%d\n",n,numscanblocks);
#endif 
	checkCudaErrors(cudaMalloc(&d_scanblocksum,numscanblocks*sizeof(int)));
	checkCudaErrors(cudaMalloc(&d_scanblockstartpts,(numscanblocks+1)*sizeof(int)));

	for(int i=0;i<numscanblocks;i++){
		int nelemtoscan=(n-scanblocksize*i)>scanblocksize ? scanblocksize : n-scanblocksize*i;
		prescan<<<1, scanblocksize/2>>>(nelemtoscan,d_binsize+i*scanblocksize,
				d_binstartpts+i*scanblocksize,d_scanblocksum+i);
	}
#ifdef DEBUG
	int* h_scanblocksum;
	h_scanblocksum     =(int*) malloc(numscanblocks*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_scanblocksum,d_scanblocksum,numscanblocks*sizeof(int),
				cudaMemcpyDeviceToHost));
	for(int i=0;i<numscanblocks;i++){
		cout<<"[debug ] scanblocksum["<<i<<"]="<<h_scanblocksum[i]<<endl;
	}
#endif
	int next = pow(2, ceil(log(numscanblocks+1)/log(2)));
	if(next > 2048){
		cout<<"error: number of elements to sort exceed the prescan capability"<<endl;
		return 1;
	}
	prescan<<<1, next/2>>>(numscanblocks,d_scanblocksum,d_scanblockstartpts,d_scanblockstartpts+numscanblocks);
#ifdef DEBUG
	int* h_scanblockstartpts = (int*) malloc((numscanblocks+1)*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_scanblockstartpts,d_scanblockstartpts,(numscanblocks+1)*sizeof(int),
				cudaMemcpyDeviceToHost));
	for(int i=0;i<numscanblocks+1;i++){
		cout<<"[debug ] scanblockstartpts["<<i<<"]="<<h_scanblockstartpts[i]<<endl;
	}
#endif
	uniformUpdate<<<numscanblocks,scanblocksize>>>(n,d_binstartpts,d_scanblockstartpts);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel BinStartPts_2d \t\t\t%.3g ms\n", milliseconds);
#endif

#ifdef DEBUG
	int *h_binstartpts;
	h_binstartpts = (int*)malloc((numbins[0]*numbins[1]+1)*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binstartpts,d_binstartpts,(numbins[0]*numbins[1]+1)*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] Result of scan bin_size array:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<"bin["<<setw(3)<<i<<","<<setw(3)<<j<<"] = "<<setw(2)<<h_binstartpts[i+j*numbins[0]];
		}
		cout<<endl;
	}
	cout<<"[debug ] Total number of nonuniform pts (include those in ghost bins) = "
		<< setw(4)<<h_binstartpts[numbins[0]*numbins[1]]<<endl;
	free(h_binstartpts);
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif

	cudaEventRecord(start);
	PtsRearrage_noghost_2d<<<(M+1024-1)/1024,1024>>>(M, nf1, nf2, bin_size_x, bin_size_y, numbins[0],
	                                                 numbins[1], d_binstartpts, d_sortidx, d_kx, d_kxsorted,
	                                                 d_ky, d_kysorted, d_c, d_csorted);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel PtsRearrange_noghost_2d \t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	FLT *h_kxsorted, *h_kysorted;
	CPX *h_csorted;
	h_kxsorted = (FLT*)malloc(M*sizeof(FLT));
	h_kysorted = (FLT*)malloc(M*sizeof(FLT));
	h_csorted  = (CPX*)malloc(M*sizeof(CPX));
	checkCudaErrors(cudaMemcpy(h_kxsorted,d_kxsorted,M*sizeof(FLT),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_kysorted,d_kysorted,M*sizeof(FLT),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_csorted,d_csorted,M*sizeof(CPX),
				cudaMemcpyDeviceToHost));
	for (int i=0; i<M; i++){
		//printf("[debug ] (x,y)=(%f, %f), bin#=%d\n", h_kxsorted[i], h_kysorted[i],
		//                                             (floor(h_kxsorted[i]/bin_size_x)+1)+numbins[0]*(floor(h_kysorted[i]/bin_size_y)+1));
		cout <<"[debug ] (x,y) = ("<<setw(10)<<h_kxsorted[i]<<","
			<<setw(10)<<h_kysorted[i]<<"), bin# =  "
			<<(floor(h_kxsorted[i]/bin_size_x))+numbins[0]*(floor(h_kysorted[i]/bin_size_y))<<endl;
	}
	free(h_kysorted);
	free(h_kxsorted);
	free(h_csorted);
#endif

	cudaEventRecord(start);
	threadsPerBlock.x = 16;
	threadsPerBlock.y = 16;
	blocks.x = numbins[0];
	blocks.y = numbins[1];
	size_t sharedmemorysize = (bin_size_x+2*ceil(ns/2.0))*(bin_size_y+2*ceil(ns/2.0))*sizeof(gpuComplex);
	if(sharedmemorysize > 49152){
		cout<<"error: not enought shared memory"<<endl;
		return 1;
	}
	// blockSize must be a multiple of bin_size_x
	Spread_2d_Hybrid<<<blocks, threadsPerBlock, sharedmemorysize>>>(d_kxsorted, d_kysorted, d_csorted, 
									d_fw, M, ns, nf1, nf2, 
									es_c, es_beta, fw_width, 
									d_binstartpts, d_binsize, 
									bin_size_x, bin_size_y);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Hybrid \t\t%.3g ms\n", milliseconds);
#endif
	// Free memory
	cudaFree(d_binsize);
	cudaFree(d_binstartpts);
	cudaFree(d_sortidx);
	cudaFree(d_kxsorted);
	cudaFree(d_kysorted);
	cudaFree(d_csorted);
	return 0;
}

int cnufftspread2d_gpu_odriven(int nf1, int nf2, int fw_width, gpuComplex* d_fw, int M, 
                               FLT *d_kx, FLT *d_ky, gpuComplex *d_c, spread_opts opts)
{
	// Timing 
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;
	
	// GPU memory
	FLT *d_kxsorted,*d_kysorted;
	gpuComplex *d_csorted;
	int *d_binsize;
	int *d_binstartpts;
	int *d_sortidx;

	// Parameter setting
	int numbins[2];
	int totalnupts;
	int nbin_block_x, nbin_block_y;
	int bin_size_x=opts.bin_size_x;
	int bin_size_y=opts.bin_size_y;

	numbins[0] = ceil(nf1/bin_size_x)+2;
	numbins[1] = ceil(nf2/bin_size_y)+2;
	// assume that bin_size_x > ns/2;
#ifdef INFO
	cout<<"[info  ] Dividing the uniform grids to bin size["
		<<opts.bin_size_x<<"x"<<opts.bin_size_y<<"]"<<endl;
	cout<<"[info  ] numbins (including ghost bins) = ["
		<<numbins[0]<<"x"<<numbins[1]<<"]"<<endl;
#endif

	checkCudaErrors(cudaMalloc(&d_binsize,numbins[0]*numbins[1]*sizeof(int)));
	checkCudaErrors(cudaMalloc(&d_sortidx,M*sizeof(int)));
	checkCudaErrors(cudaMalloc(&d_binstartpts,(numbins[0]*numbins[1]+1)*sizeof(int)));


	checkCudaErrors(cudaMemset(d_binsize,0,numbins[0]*numbins[1]*sizeof(int)));
	cudaEventRecord(start);
	cudaEventRecord(start);
	CalcBinSize_2d<<<(M+1024-1)/1024, 1024>>>(M,nf1,nf2,bin_size_x,bin_size_y,
			numbins[0],numbins[1],d_binsize,
			d_kx,d_ky,d_sortidx);
#ifdef SPREADTIME
  	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel CalcBinSize_2d \t\t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	int *h_binsize; // For debug
	h_binsize     = (int*)malloc(numbins[0]*numbins[1]*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binsize,d_binsize,numbins[0]*numbins[1]*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] Before fill in the ghost bin size:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<" bin["<<setw(3)<<i<<","<<setw(3)<<j<<"]="<<h_binsize[i+j*numbins[0]];
		}
		cout<<endl;
	}
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif
	cudaEventRecord(start);
	threadsPerBlock.x = 32;
	threadsPerBlock.y = 32;
	if(threadsPerBlock.x*threadsPerBlock.y < 1024){
		cout<<"error: number of threads in a block exceeds max num 1024("
			<<threadsPerBlock.x*threadsPerBlock.y<<")"<<endl;
		return 1;
	}
	blocks.x = (numbins[0]+threadsPerBlock.x-1)/threadsPerBlock.x;
	blocks.y = (numbins[1]+threadsPerBlock.y-1)/threadsPerBlock.y;
	FillGhostBin_2d<<<blocks,threadsPerBlock>>>(numbins[0],numbins[1],d_binsize);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel FillGhostBin_2d \t\t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	checkCudaErrors(cudaMemcpy(h_binsize,d_binsize,numbins[0]*numbins[1]*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] After fill in the ghost bin size:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<"bin["<<setw(3)<<i<<","<<setw(3)<<j<<"] = "<<h_binsize[i+j*numbins[0]];
		}
		cout<<endl;
	}
	free(h_binsize);
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif

	cudaEventRecord(start);
	int n=numbins[0]*numbins[1];
	int scanblocksize=1024;
	int numscanblocks=ceil((double)n/scanblocksize);
	int* d_scanblocksum, *d_scanblockstartpts;
#ifdef DEBUG
	printf("[debug ] n=%d, numscanblocks=%d\n",n,numscanblocks);
#endif 
	checkCudaErrors(cudaMalloc(&d_scanblocksum,numscanblocks*sizeof(int)));
	checkCudaErrors(cudaMalloc(&d_scanblockstartpts,(numscanblocks+1)*sizeof(int)));

	for(int i=0;i<numscanblocks;i++){
		int nelemtoscan=(n-scanblocksize*i)>scanblocksize ? scanblocksize : n-scanblocksize*i;
		prescan<<<1, scanblocksize/2>>>(nelemtoscan,d_binsize+i*scanblocksize,
				d_binstartpts+i*scanblocksize,d_scanblocksum+i);
	}
#ifdef DEBUG
	int* h_scanblocksum;
	h_scanblocksum     =(int*) malloc(numscanblocks*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_scanblocksum,d_scanblocksum,numscanblocks*sizeof(int),
				cudaMemcpyDeviceToHost));
	for(int i=0;i<numscanblocks;i++){
		cout<<"[debug ] scanblocksum["<<i<<"]="<<h_scanblocksum[i]<<endl;
	}
#endif
	int next = pow(2, ceil(log(numscanblocks+1)/log(2)));
	if(next > 2048){
		cout<<"error: number of elements to sort exceed the prescan capability"<<endl;
		return 1;
	}
	prescan<<<1, next/2>>>(numscanblocks,d_scanblocksum,d_scanblockstartpts,d_scanblockstartpts+numscanblocks);
#ifdef DEBUG
	int* h_scanblockstartpts = (int*) malloc((numscanblocks+1)*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_scanblockstartpts,d_scanblockstartpts,(numscanblocks+1)*sizeof(int),
				cudaMemcpyDeviceToHost));
	for(int i=0;i<numscanblocks+1;i++){
		cout<<"[debug ] scanblockstartpts["<<i<<"]="<<h_scanblockstartpts[i]<<endl;
	}
#endif
	uniformUpdate<<<numscanblocks,scanblocksize>>>(n,d_binstartpts,d_scanblockstartpts);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel BinStartPts_2d \t\t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	int *h_binstartpts;
	h_binstartpts = (int*)malloc((numbins[0]*numbins[1]+1)*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binstartpts,d_binstartpts,(numbins[0]*numbins[1]+1)*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] Result of scan bin_size array:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<"bin["<<setw(3)<<i<<","<<setw(3)<<j<<"] = "<<setw(2)<<h_binstartpts[i+j*numbins[0]];
		}
		cout<<endl;
	}
	cout<<"[debug ] Total number of nonuniform pts (include those in ghost bins) = "
		<< setw(4)<<h_binstartpts[numbins[0]*numbins[1]]<<endl;
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
	free(h_binstartpts);
#endif

	cudaEventRecord(start);
	checkCudaErrors(cudaMemcpy(&totalnupts,d_binstartpts+numbins[0]*numbins[1],sizeof(int),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMalloc(&d_kxsorted,totalnupts*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(&d_kysorted,totalnupts*sizeof(FLT)));
	checkCudaErrors(cudaMalloc(&d_csorted,totalnupts*sizeof(gpuComplex)));
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tAllocating GPU memory for sorted array \t%.3g ms\n", milliseconds);
#endif

	cudaEventRecord(start);
	PtsRearrage_2d<<<(M+1024-1)/1024,1024>>>(M, nf1, nf2, bin_size_x, bin_size_y, numbins[0],
			numbins[1], d_binstartpts, d_sortidx, d_kx, d_kxsorted,
			d_ky, d_kysorted, d_c, d_csorted);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel PtsRearrange_2d \t\t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	FLT *h_kxsorted, *h_kysorted;
	CPX *h_csorted;
	h_kxsorted = (FLT*)malloc(totalnupts*sizeof(FLT));
	h_kysorted = (FLT*)malloc(totalnupts*sizeof(FLT));
	h_csorted  = (CPX*)malloc(totalnupts*sizeof(CPX));
	checkCudaErrors(cudaMemcpy(h_kxsorted,d_kxsorted,totalnupts*sizeof(FLT),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_kysorted,d_kysorted,totalnupts*sizeof(FLT),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_csorted,d_csorted,totalnupts*sizeof(CPX),
				cudaMemcpyDeviceToHost));
	for (int i=0; i<totalnupts; i++){
		//printf("[debug ] (x,y)=(%f, %f), bin#=%d\n", h_kxsorted[i], h_kysorted[i],
		//                                             (floor(h_kxsorted[i]/bin_size_x)+1)+numbins[0]*(floor(h_kysorted[i]/bin_size_y)+1));
		cout <<"[debug ] (x,y) = ("<<setw(10)<<h_kxsorted[i]<<","
			<<setw(10)<<h_kysorted[i]<<"), bin# =  "
			<<(floor(h_kxsorted[i]/bin_size_x)+1)+numbins[0]*(floor(h_kysorted[i]/bin_size_y)+1)<<endl;
	}
	free(h_kysorted);
	free(h_kxsorted);
	free(h_csorted);
#endif

	cudaEventRecord(start);
	threadsPerBlock.x = 8;
	threadsPerBlock.y = 8;
	blocks.x = (nf1 + threadsPerBlock.x - 1)/threadsPerBlock.x;
	blocks.y = (nf2 + threadsPerBlock.y - 1)/threadsPerBlock.y;
	nbin_block_x = threadsPerBlock.x/bin_size_x<(numbins[0]-2) ? threadsPerBlock.x/bin_size_x : (numbins[0]-2);
	nbin_block_y = threadsPerBlock.y/bin_size_y<(numbins[1]-2) ? threadsPerBlock.y/bin_size_y : (numbins[1]-2);
#ifdef INFO
	cout<<"[info  ]"<<" ["<<nf1<<"x"<<nf2<<"] "<<"output elements is divided into ["
		<<blocks.x<<","<<blocks.y<<"] block"<<", each block has ["<<nbin_block_x<<"x"<<nbin_block_y<<"] bins, "
		<<"["<<threadsPerBlock.x<<"x"<<threadsPerBlock.y<<"] threads"<<endl;
#endif
	// blockSize must be a multiple of bin_size_x
	Spread_2d_Odriven<<<blocks, threadsPerBlock>>>(nbin_block_x, nbin_block_y, numbins[0], numbins[1],
			d_binstartpts, d_kxsorted, d_kysorted, d_csorted,
			d_fw, ns, nf1, nf2, es_c, es_beta, fw_width);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
  	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Odriven \t\t%.3g ms\n", milliseconds);
#endif
	// Free memory
	cudaFree(d_binsize);
	cudaFree(d_binstartpts);
	cudaFree(d_sortidx);
	cudaFree(d_kxsorted);
	cudaFree(d_kysorted);
	cudaFree(d_csorted);
	return 0;
}
