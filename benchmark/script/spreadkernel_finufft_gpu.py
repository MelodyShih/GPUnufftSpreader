import subprocess
import numpy as np
import re

def find_between( s, first, last ):
    try:
        start = s.index( first ) + len( first )
        end = s.index( last, start )
        return s[start:end]
    except ValueError:
        return ""

def main():
	nupts_distr=2
	reps=10
	density = 1.0
	N_totry = 2**np.arange(8,13)
	t_gpuspread_1 = np.zeros(len(N_totry))
	t_gpuspread_2 = np.zeros(len(N_totry))
	t_gpuspread_3 = np.zeros(len(N_totry))
	t_gpuspread_4 = np.zeros(len(N_totry))
	for i,N in enumerate(N_totry):
		M = int((N/2.0)*(N/2.0))
		# Method 1
		t = 0
		for n in range(reps):
                        output=subprocess.check_output(["./compare",'1',str(nupts_distr),str(N),str(N)], \
                                            cwd="../").decode("utf-8")
                        t+= float(find_between(output, "Spread", "ms"))
		t_gpuspread_1[i] = t/reps
		
		# Method 2
		t = 0
		for n in range(reps):
                        output=subprocess.check_output(["./compare",'2',str(nupts_distr),str(N),str(N)], \
                                            cwd="../").decode("utf-8")
                        t+= float(find_between(output, "Spread", "ms"))
		t_gpuspread_2[i] = t/reps

		# Method 3
		#t = 0
		#for n in range(reps):
                #        output=subprocess.check_output(["./compare",'3',str(nupts_distr),str(N),str(N)], \
                #                            cwd="../").decode("utf-8")
                #        t+= float(find_between(output, "Spread", "ms"))
		#t_gpuspread_3[i] = t/reps

		# Method 4
		t = 0
		for n in range(reps):
                        output=subprocess.check_output(["./compare",'4',str(nupts_distr),str(N),str(N)], \
                                            cwd="../").decode("utf-8")
                        t+= float(find_between(output, "Spread", "ms"))
		t_gpuspread_4[i] = t/reps
	
	# Output result
	print("Method 1: input driven without sort")
	for i,N in enumerate(N_totry):
		print('N={:5d}, s= {:5.3e}'.format(N,t_gpuspread_1[i]))
	print("\n")

	print("Method 2: input driven with sort")
	for i,N in enumerate(N_totry):
		print('N={:5d}, s= {:5.3e}'.format(N,t_gpuspread_2[i]))
	print("\n")

	print("Method 3: output driven")
	for i,N in enumerate(N_totry):
		print('N={:5d}, s= {:5.3e}'.format(N,t_gpuspread_3[i]))
	print("\n")

	print("Method 4: hybrid")
	for i,N in enumerate(N_totry):
		print('N={:5d}, s= {:5.3e}'.format(N,t_gpuspread_4[i]))
  
if __name__== "__main__":
  main()